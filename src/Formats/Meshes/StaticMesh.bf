using Common;
using System;
using Common.IO;
using Common.Misc;
using System.Collections;
using Common.Math;

namespace RfgTools.Formats.Meshes
{
    //For csmesh_pc/gsmesh_pc files
    public class StaticMesh
    {
        private u8[] _cpuFileDataCopy = null ~DeleteIfSet!(_);
        private u8[] _gpuFileDataCopy = null ~DeleteIfSet!(_);
        private Span<u8> _cpuFileBytes = .Empty;
        private Span<u8> _gpuFileBytes = .Empty;
        public bool Loaded { get; private set; } = false;

        public append String Name;

        public StaticMeshData* Header;
        public append MeshDataBlock MeshData;

        public append List<u32> MaterialOffsets;
        public append List<RfgMaterial> Materials;
        public append List<StringView> TextureNames;
        public Span<i32> LodSubmeshIds = .Empty;
        public Span<MeshTag> Tags = .Empty;

        //The padding is included so we can just load the files into memory and make a pointer to this data instead of manually reading each field.
        //TODO: Either make the rest of the code use memory mapped structs like this or make it all read the elements one by one. It's confusing having it do a bit of both.
        [CRepr, RequiredSize(96)]
        public struct StaticMeshData
        {
            public MeshHeaderShared Shared;

            public u32 NumLods = 0;
            private u32 _padding0;

            public i32 LodSubmeshIdOffset = 0;
            private u32 _padding1;

            public i32 TagsOffset;
            private u32 _padding2;

            public u32 NumTags;
            private u32 _padding3;

            public u32 MeshTagOffset;
            public u32 _padding4;

            public u32 CmIndex;
            public u32 _padding5;
        }

        [CRepr, RequiredSize(52)]
        public struct MeshTag
        {
            public u32 NameCrc;
            public Mat3 Rotation;
            public Vec3 Translation;
        }

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

            Header = cpuFile.GetAndSkip<StaticMeshData>();

            if (Header.Shared.Signature != 0xC0FFEE11)
                return .Err("Wrong file signature detected. Expected 0xC0FFEE11.");
            if (Header.Shared.Version != 5)
                return .Err("Unsupported ccmesh_pc version. Expected version 5.");

            if (Header.NumLods > 1)
            {
                //TODO: Make sure there's multiple IDs at the LodSubmeshIdOffset in this case. Made this case fail to make sure we catch it.
                return .Err("Static meshes with more than one LOD level not supported. Please report this error with the mesh in question to the developer.");
            }

            //TODO: Align(16) may be needed here
            cpuFile.Seek(Header.Shared.MeshOffset);
            MeshData.Read(cpuFile);

            //TODO: Align(16) may be needed here when an exporter is written.
            cpuFile.Seek(Header.Shared.MaterialMapOffset);

            //TODO: Determine if any other important data is between this and the material offsets. The null bytes might just be padding.
            u32 materialsOffsetRelative = cpuFile.Read<u32>();
            u32 numMaterials = cpuFile.Read<u32>();
            cpuFile.Seek(Header.Shared.MaterialsOffset);

            //Read material offsets
            for (int i = 0; i < numMaterials; i++)
            {
                MaterialOffsets.Add(cpuFile.Read<u32>());
                cpuFile.Skip(4);
            }

            //Read materials
            for (int i = 0; i < numMaterials; i++)
            {
                //TODO: Make sure we're not skipping any important data by doing this
                cpuFile.Seek(MaterialOffsets[i]);

                RfgMaterial material = .();
                material.Read(cpuFile);
                Materials.Add(material);
            }

            if (cpuFile.Position != Header.Shared.TextureNamesOffset)
            {
                //We should be at the texture names offset now
                return .Err("Unexpected character mesh structure. Texture names offset not expected location.");
            }

            cpuFile.Seek(Header.Shared.TextureNamesOffset);
            for (RfgMaterial material in Materials)
            {
                for (TextureDesc textureDesc in material.Textures)
                {
                    cpuFile.Seek(Header.Shared.TextureNamesOffset + textureDesc.NameOffset);
                    TextureNames.Add(cpuFile.ReadNullTerminatedStringView());
                }
            }

            cpuFile.Seek(Header.LodSubmeshIdOffset);
            LodSubmeshIds = cpuFile.GetAndSkipSpan<i32>(Header.NumLods);

            cpuFile.Seek(Header.TagsOffset);
            if (cpuFile.Position != Header.TagsOffset)
            {
                //We should be at the texture names offset now
                return .Err("Unexpected character mesh structure. Tags offset not expected location.");
            }

            Header.NumTags = cpuFile.Read<u32>();
            Tags = cpuFile.GetAndSkipSpan<MeshTag>(Header.NumTags);

            return .Ok;
        }
    }
}