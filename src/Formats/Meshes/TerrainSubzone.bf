using System.Collections;
using Common.Misc;
using Common.IO;
using Common;
using System;
using Common.Math;

namespace RfgTools.Formats.Meshes
{
    //Contains high lod meshes and metadata for the terrain of a subzone (1/9th) of a map zone. Each map zone has 9 of these files. Extension = ctmesh_pc|gtmesh_pc.
    public class TerrainSubzone
    {
        private u8[] _cpuFileDataCopy = null ~DeleteIfSet!(_);
        private u8[] _gpuFileDataCopy = null ~DeleteIfSet!(_);
        private Span<u8> _cpuFileBytes = .Empty;
        private Span<u8> _gpuFileBytes = .Empty;
        public bool Loaded { get; private set; } = false;

        public Header* Header = null;

        //Terrain data
        public append List<String> StitchPieceNames ~ClearAndDeleteItems(_);
        public TerrainSubzoneData* Data = null;
        public Span<TerrainPatch> Patches = .Empty;
        public append MeshDataBlock TerrainMesh;

        //Stitch piece data
        public Span<TerrainStitchInstance> StitchInstances = .Empty;
        public append List<String> StitchPieceNames2 ~ClearAndDeleteItems(_);
        public append MeshDataBlock StitchMesh;

        //Road data
        public Span<RoadMeshData> RoadMeshesData = .Empty;
        public append List<MeshDataBlock> RoadMeshes ~ClearAndDeleteItems(_);
        public append List<RfgMaterial> RoadMaterials;
        public append List<List<String>> RoadTextures;

        public bool HasStitchMesh { get; private set; } = false;

        [CRepr, RequiredSize(16)]
        public struct Header
        {
            public u32 Signature;
            public u32 Version;
            public u32 Index;
            public u32 NumStitchPieceNames;
        }

        public ~this()
        {
            for (List<String> stringList in RoadTextures)
                DeleteContainerAndItems!(stringList);
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

            Header = cpuFile.GetAndSkip<TerrainSubzone.Header>();
            if (Header.Signature != 1514296659) //ASCII string "SUBZ"
                return .Err("Wrong file signature detected. Expected 1514296659.");
            if (Header.Version != 31)
                return .Err("Unsupported cterrain_pc version. Expected version 31.");

            u32 stitchPieceNamesSize = cpuFile.Read<u32>();
            cpuFile.ReadSizedStringList(stitchPieceNamesSize, StitchPieceNames);
            cpuFile.Align2(4);

            Data = cpuFile.GetAndSkip<TerrainSubzoneData>();

            Patches = cpuFile.GetAndSkipSpan<TerrainPatch>(Data.PatchCount);
            cpuFile.Align2(16);

            TerrainMesh.Read(cpuFile);
            cpuFile.Align2(4);

            //Read stitch piece data
            StitchInstances = cpuFile.GetAndSkipSpan<TerrainStitchInstance>(Data.NumStitchPieces);
            for (int i in 0 ..< Data.NumStitchPieces)
            {
                //TODO: Read stitch piece name
                StitchPieceNames2.Add(cpuFile.ReadStrC(.. new String()));
                cpuFile.Skip(1); //Move past null terminator
                cpuFile.Align2(4);
                cpuFile.Skip(4);

                //Todo: Fix this stupid hack
                //Skip unknown data that's between some strings
                if (i < Data.NumStitchPieces - 1)
                {
                    while (cpuFile.Peek<u8>() < 33 || cpuFile.Peek<u8>() > 126)
                        cpuFile.Skip(4);
                }
            }
            cpuFile.Skip(4);

            //Read stitch mesh data
            if (Data.NumRoadDecalMeshes > 0)
            {
                HasStitchMesh = true;

                //TODO: Come up with a less hacky way of doing this
                //Skip unknown data before stitch mesh header that has indices which can be parsed
                u32 i = cpuFile.Read<u32>();
                while (true)
                {
                    if (cpuFile.Peek<u8>() == 0)
                    {
                    	cpuFile.Skip(4);
                    }
                    else if ((u32)cpuFile.Peek<u8>() == i + 1)
                    {
                    	cpuFile.Skip(4);
                    	i++;

                    	//Hit version at start of mesh data block, stop
                    	if (cpuFile.Peek<u8>() != 0)
                    	{
                            cpuFile.Seek(cpuFile.Position - 4, .Absolute); //Relative seek hasn't been implemented yet
                    		break;
                    	}
                    }
                    else
                    	break;
                }

                cpuFile.Align2(16);
                if (StitchMesh.Read(cpuFile) case .Err(StringView err))
                    return .Err(err);
            }
            cpuFile.Align2(4);

            //Read road mesh data
            if (Data.NumRoadDecalMeshes > 0)
            {
                RoadMeshesData = cpuFile.GetAndSkipSpan<RoadMeshData>(Data.NumRoadDecalMeshes);
                for (int i in 0 ..< Data.NumRoadDecalMeshes)
                {
                    MeshDataBlock mesh = new .();

                    cpuFile.Align2(16);
                    if (mesh.Read(cpuFile) case .Err(StringView err))
                    {
                        delete mesh;
                        return .Err(err);
                    }
                    cpuFile.Align2(4);

                    //TODO: Fix this hack
                    //Skip null data of varying size
                    while (cpuFile.Peek<u32>() == 0)
                    {
                        cpuFile.Skip(4);
                    }

                    u32 textureNamesSize = cpuFile.Read<u32>();
                    List<String> textureNames = new .();
                    cpuFile.ReadSizedStringList(textureNamesSize, textureNames);
                    RoadTextures.Add(textureNames);

                    cpuFile.Align2(16);
                    cpuFile.Skip(16);
                    cpuFile.Align2(16);

                    RfgMaterial material = .();
                    if (material.Read(cpuFile) case .Err)
                    {
                        return .Err("Failed to read road mesh material");
                    }
                    RoadMaterials.Add(material);
                }
            }

            Loaded = true;
            return .Ok;
        }

        public Result<MeshInstanceData, StringView> GetTerrainMeshData()
        {
            if (!Loaded)
	            return .Err("Mesh not loaded. You must call TerrainSubzone.Load() before calling GetTerrainMeshData()");

            MeshInstanceData mesh = .();
            ByteSpanStream gpuFile = scope .(_gpuFileBytes);

            u32 startCRC = gpuFile.Read<u32>();
            if (startCRC != TerrainMesh.Header.VerificationHash)
                return .Err("Start CRC mismatch for terrain mesh in gtmesh_pc file");

            //Read index buffer
            gpuFile.Seek(TerrainMesh.Header.IndicesOffset);
            mesh.IndexBuffer = gpuFile.GetAndSkipSpan<u8>(TerrainMesh.Header.NumIndices * TerrainMesh.Header.IndexSize);

            //Read vertex buffer
            gpuFile.Seek(TerrainMesh.Header.VerticesOffset);
            mesh.VertexBuffer = gpuFile.GetAndSkipSpan<u8>(TerrainMesh.Header.NumVertices * TerrainMesh.Header.VertexStride0);

            //Sanity check. CRC at the end of the mesh data should match the start
            u32 endCRC = gpuFile.Read<u32>();
            if (startCRC != endCRC)
                return .Err("End CRC mismatch for terrain mesh in gterrain_pc file");

            mesh.Config = TerrainMesh;
            return .Ok(mesh);
        }

        public Result<MeshInstanceData, StringView> GetStitchMeshData()
        {
            if (!Loaded)
	            return .Err("Mesh not loaded. You must call TerrainSubzone.Load() before calling GetStitchMeshData()");
            if (!HasStitchMesh)
                return .Err("This terrain subzone has no stitch meshes.");

            MeshInstanceData mesh = .();
            ByteSpanStream gpuFile = scope .(_gpuFileBytes);

            //Skip terrain mesh data
            gpuFile.Seek(TerrainMesh.Header.VerticesOffset);
            gpuFile.Skip(TerrainMesh.Header.NumVertices * TerrainMesh.Header.VertexStride0);
            gpuFile.Skip(4); //Skip verification hash

            //Start of stitch mesh data
            gpuFile.Align2(16);
            i64 startPos = gpuFile.Position;
            u32 startCRC = gpuFile.Read<u32>();
            if (startCRC != StitchMesh.Header.VerificationHash)
                return .Err("Start CRC mismatch for stitch meshes in gtmesh_pc file");

            //Read index buffer
            gpuFile.Seek(startPos + StitchMesh.Header.IndicesOffset);
            mesh.IndexBuffer = gpuFile.GetAndSkipSpan<u8>(StitchMesh.Header.NumIndices * StitchMesh.Header.IndexSize);

            //Read vertex buffer
            gpuFile.Seek(startPos + StitchMesh.Header.VerticesOffset);
            mesh.VertexBuffer = gpuFile.GetAndSkipSpan<u8>(StitchMesh.Header.NumVertices * StitchMesh.Header.VertexStride0);

            //Sanity check. CRC at the end of the mesh data should match the start
            u32 endCRC = gpuFile.Read<u32>();
            if (startCRC != endCRC)
                return .Err("End CRC mismatch for stitch meshes in gterrain_pc file");

            mesh.Config = StitchMesh;
            return .Ok(mesh);
        }

        public Result<void, StringView> GetRoadMeshData(List<MeshInstanceData> meshes)
        {
            if (!Loaded)
	            return .Err("Mesh not loaded. You must call TerrainSubzone.Load() before calling GetRoadMeshData()");
            if (Data.NumRoadDecalMeshes == 0)
                return .Err("This terrain subzone has no road meshes.");

            ByteSpanStream gpuFile = scope .(_gpuFileBytes);

            //Skip terrain mesh data
            gpuFile.Seek(TerrainMesh.Header.VerticesOffset);
            gpuFile.Skip(TerrainMesh.Header.NumVertices * TerrainMesh.Header.VertexStride0);
            gpuFile.Skip(4); //Skip verification hash

            //Skip stitch mesh data
            gpuFile.Align2(16);
            i64 stitchStartPos = gpuFile.Position;
            gpuFile.Seek(stitchStartPos + StitchMesh.Header.VerticesOffset);
            gpuFile.Skip(StitchMesh.Header.NumVertices * StitchMesh.Header.VertexStride0);
            gpuFile.Skip(4); //Skip verification hash

            //Start of road mesh data
            for (int i in 0 ..< RoadMeshes.Count)
            {
                MeshDataBlock config = RoadMeshes[i];
                MeshInstanceData mesh = .();
                mesh.Config = config;

                gpuFile.Align2(16);
                i64 startPos = gpuFile.Position;
                u32 startCRC = gpuFile.Read<u32>();
                if (startCRC != config.Header.VerificationHash)
	                return .Err("Start CRC mismatch for road mesh in gtmesh_pc file");

                //Read index buffer
                gpuFile.Align2(16);
                gpuFile.Seek(startPos + config.Header.IndicesOffset);
                mesh.IndexBuffer = gpuFile.GetAndSkipSpan<u8>(config.Header.NumIndices * config.Header.IndexSize);

                //Read vertex buffer
                gpuFile.Seek(startPos + config.Header.VerticesOffset);
                mesh.VertexBuffer = gpuFile.GetAndSkipSpan<u8>(config.Header.NumVertices * config.Header.VertexStride0);

                u32 endCRC = gpuFile.Read<u32>();
                if (startCRC != endCRC)
                    return .Err("End CRC mismatch for road mesh in gterrain_pc file");

                meshes.Add(mesh);
            }

            return .Ok;
        }
    }

    [CRepr, RequiredSize(1104)]
    public struct TerrainSubzoneData
    {
        public u32 SubzoneIndex;
        public Vec3 Position;
        public u32 PatchCount;
        public u32 PatchesOffset;
        public TerrainRenderableData RenderableData;
        public u32 NumDecals;
        public u32 DecalsOffset;
        public u32 StitchMeshDataOffset;
        public u32 StitchRenderableOffset;
        public u32 NumStitchPieces;
        public u32 StitchPiecesOffset;
        public u32 NumRoadDecalMeshes;
        public u32 RoadDecalMeshesOffset;
        public u32 HeaderVersion;
        public u8[996] Padding;
    }

    [CRepr, RequiredSize(48)]
    public struct TerrainRenderableData
    {
        public u32 MeshDataOffset;
        public u32 RenderableOffset;
        public BoundingBox Aabb;
        public Vec3 BspherePosition;
        public f32 BsphereRadius;
    }

    [CRepr, RequiredSize(96)]
    public struct TerrainPatch
    {
        public u32 InstanceOffset;
        public Vec3 Position;
        public Mat3 Rotation;
        public u32 SubmeshIndex;
        public BoundingBox LocalAabb;
        public Vec3 LocalBspherePosition;
        public f32 LocalBsphereRadius;
    }

    [CRepr, RequiredSize(72)]
    public struct TerrainStitchInstance
    {
        public u32 StitchChunkNameOffset;
        public u32 NumSkirts;
        public u32 SkirtsOffset;
        public u32 NumStitchedSkirts;
        public u32 StitchedSkirtsOffset;
        public Vec3 Position;
        public Mat3 Rotation;
        public u32 HavokHandle;
    }

    [CRepr, RequiredSize(40)]
    public struct RoadMeshData
    {
        public u32 NumMeshInstances;
        public u32 MaterialOffset;
        public u32 MaterialHandle;
        public u32 MaterialMapOffset;
        public u32 MeshDataOffset;
        public u32 MeshOffset;
        public u32 RenderableOffset;
        public Vec3 Position;
    }
}