using Common;
using System;
using Common.IO;
using Common.Misc;
using Common.Math;
using System.IO;
using System.Collections;

namespace RfgTools.Formats.Meshes
{
    [Reflect(.All)]
	public class MeshDataBlock
	{
        public MeshHeader Header;
        public List<SubmeshData> Submeshes = new .() ~delete _;
        public List<RenderBlock> RenderBlocks = new .() ~delete _;

        [CRepr, RequiredSize(48), Reflect(.All)]
        public struct MeshHeader
        {
            public u32 Version;
            public u32 VerificationHash;
            public u32 CpuDataSize;
            public u32 GpuDataSize;
            public u32 NumSubmeshes;
            public u32 SubmeshesOffset;

            //Vertices layout
            public u32 NumVertices;
            public u8 VertexStride0;
            public VertexFormat VertexFormat;
            public u8 NumUvChannels;
            public u8 VertexStride1;
            public u32 VerticesOffset;

            //Indices layout
            public u32 NumIndices;
            public u32 IndicesOffset;
            public u8 IndexSize;
            public PrimitiveType PrimitiveType;
            public u16 NumRenderBlocks;
        }

        public Result<void, StringView> Read(ByteSpanStream stream, bool patchBufferOffsets = false)
        {
            i64 startPos = stream.Position;

            if (stream.Read<MeshHeader>() case .Ok(let val))
                Header = val;
            else
                return .Err("Failed to read mesh header");

            stream.Align2(16);
            for (int i in 0 ..< Header.NumSubmeshes)
            {
                if (stream.Read<SubmeshData>() case .Ok(let val))
                    Submeshes.Add(val);
                else
                    return .Err("Failed to read submeshes");
            }

            int numRenderBlocks = 0;
            for (var submesh in ref Submeshes)
            {
				numRenderBlocks += submesh.NumRenderBlocks;
            }
            for (int i in 0 ..< numRenderBlocks)
            {
                if (stream.Read<RenderBlock>() case .Ok(let val))
                    RenderBlocks.Add(val);
                else
                    return .Err("Failed to read render blocks");
            }

            //Todo: Fix this for files like gterrain_pc and gtmesh_pc that have multiple meshes. Seems to need absolute offset to calculate correct align pad. Luckily they have correct offsets by default
            //Patch vertex and index offset since some files don't have correct values.
            if (patchBufferOffsets)
            {
                Header.IndicesOffset = 16;
                u32 indicesEnd = Header.IndicesOffset + (Header.NumIndices * Header.IndexSize);
                Header.VerticesOffset = indicesEnd + (u32)(Stream.CalcAlignment(indicesEnd, 16));
            }

            //Patch render block offsets for easy access later
            u32 renderBlockOffset = 0;
            for (var submesh in ref Submeshes)
            {
                submesh.RenderBlocksOffset = renderBlockOffset;
                renderBlockOffset += submesh.NumRenderBlocks;
            }

            u32 endVerificationHash = stream.Read<u32>();
            if (Header.VerificationHash != endVerificationHash)
                return .Err("MeshDataBlock verification hash mismatch.");
            if (stream.Position - startPos != Header.CpuDataSize)
                return .Err("MeshDataBlock size doesn't match the expected size.");

            return .Ok;
        }

        public void Clone(MeshDataBlock clone)
        {
            clone.Header = this.Header;
            clone.Submeshes.Set(this.Submeshes);
            clone.RenderBlocks.Set(this.RenderBlocks);
        }
	}

    [CRepr, RequiredSize(44), Reflect(.All)]
    public struct SubmeshData
    {
        public u32 NumRenderBlocks;
        public Vec3 Offset;
        public Vec3 Bmin;
        public Vec3 Bmax;
        public u32 RenderBlocksOffset;
    }

    [CRepr, RequiredSize(20), Reflect(.All)]
    public struct RenderBlock
    {
        public u16 MaterialMapIndex;
        public u32 StartIndex;
        public u32 NumIndices;
        public u32 MinIndex;
        public u32 MaxIndex;
    }
}