using Common;
using System;
using System.IO;
using Common.IO;
using System.Collections;
using Common.Math;
using Common.Misc;
using System.Diagnostics;

namespace RfgTools.Formats.Meshes
{
    //Chunk mesh. Buildings and other destructible objects are stored in this format. Extension = cchk_pc|gchk_pc
    public class ChunkMesh
    {
        private u8[] _cpuFileDataCopy = null ~DeleteIfSet!(_);
        private u8[] _gpuFileDataCopy = null ~DeleteIfSet!(_);
        private Span<u8> _cpuFileBytes = .Empty;
        private Span<u8> _gpuFileBytes = .Empty;
        public bool Loaded { get; private set; } = false;

        public Header* Header = null;

        public MeshDataBlock MeshHeader = new .() ~delete _;
        public append List<String> Textures ~ClearAndDeleteItems!(_);
        public append List<Destroyable> Destroyables ~ClearAndDeleteItems!(_);

        const u32 ExpectedSignature = 2966351781;
        const u32 ExpectedVersion = 56;
        const u32 ExpectedSourceVersion = 20;

        [CRepr, RequiredSize(48)]
        public struct Header
        {
            public u32 Signature = 0;
            public u32 Version = 0;
            public u32 SourceVersion = 0;
            public u32 RenderDataChecksum = 0;
            public u32 RenderCpuDataOffset = 0;
            public u32 RenderCpuDataSize = 0;
            public u32 CollisionModelChecksum = 0;
            public u32 CollisionModelDataOffset = 0;
            public u32 CollisionModelDataSize = 0;
            public u32 DestructionChecksum = 0;
            public u32 DestructionOffset = 0;
            public u32 DestructionDataSize = 0;
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

            //Validate header
            Header = cpuFile.GetAndSkip<ChunkMesh.Header>();
            if (Header.Signature != ExpectedSignature)
                return .Err("Invalid format signature");
            if (Header.Version != ExpectedVersion)
                return .Err("Unsupported format version");
            if (Header.SourceVersion != ExpectedSourceVersion)
                return .Err("Unsupported format source version");

            //Skip some unknown data. Skipped/read in the current best guess for how the data is structured
            cpuFile.Skip(400);
            u32 unkValue0 = cpuFile.Read<u32>();
            cpuFile.Skip(28);
            u32 unkValue1 = cpuFile.Read<u32>();
            cpuFile.Skip(32);
            u32 unkValue2 = cpuFile.Read<u32>();
            cpuFile.Skip(184);

            //Should be at the render data offset
            if (cpuFile.Position != Header.RenderCpuDataOffset)
            	return .Err("Error! Haven't reached the chunk render data section when expected!");

            //Read mesh header
            MeshHeader.Read(cpuFile);

            //Read texture names
            cpuFile.Align2(16);
            u32 textureNamesBlockSize = cpuFile.Read<u32>();
            cpuFile.ReadSizedStringList(textureNamesBlockSize, Textures);

            //TODO: Figure out what this data is
            //Some kind of material data
            cpuFile.Align2(16);
            u32 materialOffset = cpuFile.Read<u32>();
            u32 numMaterials = cpuFile.Read<u32>();
            cpuFile.Skip(numMaterials * 4); //Potentially a list of material IDs or offsets
            cpuFile.Skip(materialOffset);
            cpuFile.Skip(numMaterials * 8);
            cpuFile.Align2(16);

            //TODO: Figure out what data is between here and the destroyables list

            //Skip to destroyables. Haven't fully reversed the format yet
            cpuFile.Seek(Header.DestructionOffset, .Absolute);
            cpuFile.Align2(128);
            u32 numDestroyables = cpuFile.Read<u32>();
            cpuFile.Skip((numDestroyables * 8) + 4);
            cpuFile.Align2(16);

            //Read destroyables
            for (int i in 0 ..< numDestroyables)
            {
                //Create new destroyable instance
                Destroyable destroyable = Destroyables.Add(.. new .());
                i64 destroyableStartPos = cpuFile.Position;

                //Read base data and align to next piece of data
                destroyable.Header = cpuFile.GetAndSkip<DestroyableHeader>();
                cpuFile.Align2(128);

                //Read base object data
                destroyable.Subpieces = cpuFile.GetAndSkipSpan<Subpiece>(destroyable.Header.NumObjects);
                destroyable.SubpieceData = cpuFile.GetAndSkipSpan<SubpieceData>(destroyable.Header.NumObjects);

                //Todo: Figure out what this data is meant to be. Game has some physical material code here. Maybe link material
                for (ref Subpiece subpiece in ref destroyable.Subpieces)
                    cpuFile.Skip(subpiece.NumLinks * 2);

                cpuFile.Align2(4);

                //Read links
                destroyable.Links = cpuFile.GetAndSkipSpan<Link>(destroyable.Header.NumLinks);
                cpuFile.Align2(4);

                //Read dlods
                destroyable.Dlods = cpuFile.GetAndSkipSpan<Dlod>(destroyable.Header.NumDlods);
                cpuFile.Align2(4);

                //TODO: Fix this. There's other format data here that we should be reading. Currently skipped with the hack with partial success as a temporary workaround to continue NF development.
                //Hacky way to find the next destroyable. Doesn't reliably work. I aim to fix it before the full v1.0.0 release of the Nanoforge rewrite
                Span<u32> cpuFileBytesAsU32List = .((u32*)cpuFileBytes.Ptr, cpuFileBytes.Length / 4);
                if (i != numDestroyables - 1 && numDestroyables > 1)
                {
                    i64 k = cpuFile.Position / sizeof(u32);
                    let posMax = cpuFile.Length / sizeof(u32);
                    bool destroyableNotFound = false;
                    while (true)
                    {
                        if (k >= posMax)
                        {
                            destroyableNotFound = true;
                            break;
                        }

                        //Loop through cpuFile as an in memory array of u32s. Much quicker than using BinaryReader which uses streams under the hood
                        u32 val = cpuFileBytesAsU32List[k];
                        k += 1;
                        i64 posReal = k * sizeof(u32);
                        i64 posU32 = k;
                        if (val == 0xFFFFFFFF)
                        {
                            //Might've reached destroyable_base.inst_data_offset. Verify by seeing a value then a bunch of null bytes follow
                            k += 2; //cpuFile.Skip(8);
                            const i64 nullCheckCount = 7; //Could do more, usually 18 * 4 null bytes
                            bool notFound = false;
                            for (i64 l = 0; l < nullCheckCount; l++)
                            {
                                u32 val2 = cpuFileBytesAsU32List[k + l]; //cpuFile.ReadUint32();
                                if (val2 == 0)
                                {
                                    continue;
                                }
                                else
                                {
                                    notFound = true;
                                    break;
                                }
                            }

                            if (notFound)
                            {
                                //Not found, seek back to start of scanned data
                                k = posU32;
                                continue;
                            }
                            else
                            {
                                //Seek to start of destroyable data
                                posReal -= 36;//40;
                                cpuFile.Seek(posReal, .Absolute);
                                break;
                            }
                        }
                    }

                    if (destroyableNotFound)
                    {
                        //return .Err("Next destroyable not found. This is a known bug that will be fixed before v1.0.0 of Nanoforge");
                        break;
                    }
                }
            }

            //Skip collision models. Some kind of havok data format that hasn't been reversed yet.
            cpuFile.Seek(Header.CollisionModelDataOffset, .Absolute);
            if (SkipHavokData(cpuFile) case .Err)
	            return .Err("Read error. Invalid or unsupported RFG file format.");

            //Read destroyable UIDs, names, indices
            cpuFile.Align2(128);
            for (int i in 0 ..< Destroyables.Count)
            {
                u32 uid = cpuFile.Read<u32>();

                //Read destroyable name which is up to 24 characters long
                String name = cpuFile.ReadFixedLengthString(24, .. scope .());
                while (name.EndsWith('\0') && name.Length > 0)
                    name.RemoveFromEnd(1); //Remove extra null terminators

                i32 destroyableIndex = cpuFile.Read<i32>();
                u32 isDestroyable = cpuFile.Read<u32>();
                u32 numSnapPoints = cpuFile.Read<u32>();

                //Note: This is only here since the code can't reliably read all destroyables yet. Can be removed once fixed. See the stupid hack on line 129
                if (destroyableIndex >= Destroyables.Count || destroyableIndex < 0)
                {
                    cpuFile.Skip(10 * sizeof(ChunkSnapPoint));
                    continue;
                }
                if (numSnapPoints > 10)
                {
                    return .Err("Encountered chunk destroyable with > 10 snap points! That isn't supported.");
                }

                Destroyable destroyable = Destroyables[destroyableIndex];
                destroyable.UID = uid;
                destroyable.Name.Set(name);
                destroyable.IsDestroyable = isDestroyable;
                destroyable.NumSnapPoints = numSnapPoints;
                for (int i in 0 ..< 10)
                {
                    destroyable.SnapPoints[i] = cpuFile.Read<ChunkSnapPoint>();
                }
            }

            Loaded = true;
            return .Ok;
        }

        const u32 HavokSignature = 1212891981;
        public Result<void> SkipHavokData(ByteSpanStream cpuFile)
        {
            i64 startPos = cpuFile.Position;
            u32 maybeSignature = cpuFile.Read<u32>();
            if (maybeSignature != HavokSignature)
                return .Err;

            cpuFile.Skip(4);
            u32 size = cpuFile.Read<u32>();
            cpuFile.Seek(startPos + size);
            return .Ok;
        }

        //Get vertex and index buffers + their layout info. The mesh info only stays alive as long as the ChunkMesh classes data is alive.
        public Result<MeshInstanceData, StringView> GetMeshData()
        {
            if (!Loaded)
                return .Err("Mesh not loaded. You must call Load() before calling GetMeshData()");

            MeshInstanceData mesh = .();
            MeshDataBlock config = MeshHeader;

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

    [CRepr, RequiredSize(44)]
    public struct DestroyableHeader
    {
        public u32 AabbTreeOffset; //rfg_rbb_node offset
        public u32 ObjectsOffset; //rfg_subpiece_base offset
        public u32 ExtraDataOffset; //rfg_subpiece_base_extra_data offset
        public i32 NumObjects;
        public u32 BaseLinksOffset; //rfg_links_base offset
        public i32 NumLinks;
        public u32 DlodsOffset; //rfg_dlod_base offset
        public i32 NumDlods;
        public u32 InstanceDataOffset; //rfg_destroyable_base_instance_data offset
        public u32 TransformBufferOffset; //unsigned char buffer offset
        public f32 Mass;
    }

    public class Destroyable
    {
        //TODO: Remove data we won't need after reading (like NumX which can be grabbed from vector), or which isn't set until runtime (probably most of the offsets)
        public DestroyableHeader* Header;

        public Span<Subpiece> Subpieces;
        public Span<SubpieceData> SubpieceData;
        public Span<Link> Links;
        public Span<Dlod> Dlods;

        //Note: These aren't read by ChunkMesh::Read(). Chunk format hasn't been 100% reversed yet.
        public append List<RbbNode> RbbNodes;
        public DestroyableInstanceData InstanceData;
        
        //Additional data stored in a separate part of the chunk file
        public u32 UID;
        public String Name = new .() ~delete _;
        public u32 IsDestroyable;
        public u32 NumSnapPoints;
        public ChunkSnapPoint[10] SnapPoints;
    }

    [CRepr, RequiredSize(48)]
    struct ChunkSnapPoint
    {
        public Mat3 Orient;
        public Vec3 Position;
    }

    [CRepr, RequiredSize(64)]
    struct Subpiece
    {
        public Vec3 Bmin;
        public Vec3 Bmax;
        public Vec3 Position;
        public Vec3 CenterOfMass;
        public f32 Mass;
        public u32 DlodKey;
        public u32 LinksOffset; //ushort offset
        public u8 PhysicalMaterialIndex;
        public u8 ShapeType;
        public u8 NumLinks;
        public u8 Flags;
    }

    [CRepr, RequiredSize(12)]
    struct SubpieceData
    {
        public u32 ShapeOffset; //havok shape offset
        public u16 CollisionModel;
        public u16 RenderSubpiece;
        public u32 Unknown0;
    }

    [CRepr, RequiredSize(16)]
    struct Link
    {
        public i32 YieldMax;
        public f32 Area;
        public i16[2] Obj;
        public u8 Flags;
    }

    [CRepr, RequiredSize(60)]
    struct Dlod
    {
        public u32 NameHash;
        public Vec3 Pos;
        public Mat3 Orient;
        public u16 RenderSubpiece;
        public u16 FirstPiece;
        public u8 MaxPieces;
    }

    [CRepr, RequiredSize(12)]
    struct RbbAabb
    {
        public i16 MinX;
        public i16 MinY;
        public i16 MinZ;
        public i16 MaxX;
        public i16 MaxY;
        public i16 MaxZ;
    }

    [CRepr, RequiredSize(20)]
    struct RbbNode
    {
        public i32 NumObjects;
        public RbbAabb Aabb;
        public u32 NodeDataOffset; //et_ptr_offset<unsigned char, 0> node_data;
    }

    [CRepr, RequiredSize(20)]
    struct DestroyableInstanceData
    {
        public u32 ObjectsOffset;
        public u32 LinksOffset;
        public u32 DlodsOffset;
        public u32 DataSize;
        public u32 BufferOffset; //et_ptr_offset<unsigned char, 0> buffer;
    }
}