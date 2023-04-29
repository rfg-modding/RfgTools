using Common;
using System;
using System.IO;
using Common.IO;
using System.Collections;
using Common.Math;
using Common.Misc;

namespace RfgTools.Formats.Meshes
{
    //Rock mesh. Extension = cstch_pc|gstch_pc
    public class RockMesh
    {
        private u8[] _cpuFileDataCopy = null ~DeleteIfSet!(_);
        private u8[] _gpuFileDataCopy = null ~DeleteIfSet!(_);
        private Span<u8> _cpuFileBytes = .Empty;
        private Span<u8> _gpuFileBytes = .Empty;
        public bool Loaded { get; private set; } = false;

        public MeshDataBlock MeshData = new .() ~delete _;
        public append List<String> TextureNames ~ClearAndDeleteItems!(_);

        public Result<void, StringView> Load(Span<u8> cpuFileBytes, Span<u8> gpuFileBytes, bool useInPlace = false)
        {
            if (useInPlace)
            {
                //Keep reference to the spans. They must stay alive as long as this class for things to work correctly
                _cpuFileBytes = cpuFileBytes;
                _gpuFileBytes = gpuFileBytes;
            }
            else
            {
                //Make a copy of the data so it stays alive as long as the object
                _cpuFileDataCopy = new u8[cpuFileBytes.Length];
                Internal.MemCpy(&_cpuFileDataCopy[0], cpuFileBytes.Ptr, cpuFileBytes.Length);
                _gpuFileDataCopy = new u8[gpuFileBytes.Length];
                Internal.MemCpy(&_gpuFileDataCopy[0], gpuFileBytes.Ptr, gpuFileBytes.Length);

                _cpuFileBytes = _cpuFileDataCopy;
                _gpuFileBytes = _gpuFileDataCopy;
            }
            ByteSpanStream cpuFile = scope .(_cpuFileBytes);

            //TODO: See if signature + version can check can be added here. Not all formats have them so may not be possible

            //Get the offset of the MeshDataBlock. Always at offset 16
            cpuFile.Seek(16, .Absolute);
            u32 meshHeaderOffset = cpuFile.Read<u32>();
            cpuFile.Seek(meshHeaderOffset, .Absolute);

            //Read mesh config
            if (MeshData.Read(cpuFile) case .Err(StringView err))
                return .Err(err);

            //Read texture names
            cpuFile.Align2(16);
            u32 textureNamesSize = cpuFile.Read<u32>();
            cpuFile.ReadSizedStringList(textureNamesSize, TextureNames);

            Loaded = true;
            return .Ok;
        }

        //Get vertex and index buffers + their layout info. The mesh info only stays alive as long as the RockMesh classes data is alive.
        public Result<MeshInstanceData, StringView> GetMeshData()
        {
            if (!Loaded)
                return .Err("Mesh not loaded. You must call RockMesh.Load() before calling GetMeshData()");

            MeshInstanceData mesh = .();
            MeshDataBlock config = MeshData;

            ByteSpanStream gpuFile = scope .(_gpuFileBytes);
            gpuFile.Seek(16, .Absolute);

            //Read indices
            mesh.IndexBuffer = gpuFile.GetAndSkipSpan<u8>(config.Header.NumIndices * config.Header.IndexSize);

            gpuFile.Align2(16);
            mesh.VertexBuffer = gpuFile.GetAndSkipSpan<u8>(config.Header.NumVertices * config.Header.VertexStride0);

            mesh.Config = config;
            return mesh;
        }
    }
}