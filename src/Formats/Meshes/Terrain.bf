using Common;
using System;
using System.IO;
using Common.IO;
using System.Collections;
using Common.Math;
using Common.Misc;

namespace RfgTools.Formats.Meshes
{
    //Contains low lod meshes and metadata for the terrain of one map zone. Extension = cterrain_pc|gterrain_pc.
    public class Terrain
    {
        private u8[] _cpuFileDataCopy = null ~DeleteIfSet!(_);
        private u8[] _gpuFileDataCopy = null ~DeleteIfSet!(_);
        private Span<u8> _cpuFileBytes = .Empty;
        private Span<u8> _gpuFileBytes = .Empty;
        public bool Loaded { get; private set; } = false;

        public Header* Header = null;
        public append List<String> TextureNames ~ClearAndDeleteItems(_);
        public append List<String> StitchPieceNames ~ClearAndDeleteItems(_);
        public append List<String> FmeshNames ~ClearAndDeleteItems(_);
        public Span<TerrainStitchInfo> StitchPieces = .Empty;
        public TerrainData* Data = null;

        public append List<String> TerrainMaterialNames ~ClearAndDeleteItems(_);
        public append List<RfgMaterial> Materials;
        public append List<SidemapMaterial> SidemapMaterials ~ClearAndDeleteItems(_);
        public append List<String> LayerMapMaterialNames ~ClearAndDeleteItems(_);
        public append List<String> LayerMapMaterialNames2 ~ClearAndDeleteItems(_);

        public Span<UndergrowthLayerData> UndergrowthLayers = .Empty;
        public Span<UndergrowthCellLayerData> UndergrowthCellData = .Empty;
        public Span<SingleUndergrowthCellLayerData> SingleUndergrowthCellData = .Empty;
        public Span<SingleUndergrowthData> SingleUndergrowthData = .Empty;

        public append List<String> MinimapMaterialNames ~ClearAndDeleteItems(_);
        public RfgMaterial MinimapMaterials;

        public MeshDataBlock[9] Meshes;

        [CRepr, RequiredSize(36)]
        public struct Header
        {
            public u32 Signature;
            public u32 Version;
            public u32 NumTextureNames;
            public u32 TextureNamesSize;
            public u32 NumFmeshNames;
            public u32 FmeshNamesSize;
            public u32 StitchPieceNamesSize;
            public u32 NumStitchPieceNames;
            public u32 NumStitchPieces;
        }

        public ~this()
        {
            for (int i in 0 ... 8)
                delete Meshes[i];
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

            Header = cpuFile.GetAndSkip<Terrain.Header>();
            if (Header.Signature != 1381123412) //ASCII string "TERR"
                return .Err("Wrong file signature detected. Expected 1381123412.");
            if (Header.Version != 31)
                return .Err("Unsupported cterrain_pc version. Expected version 31.");

            cpuFile.ReadSizedStringList(Header.TextureNamesSize, TextureNames);
            cpuFile.Align2(4);

            cpuFile.ReadSizedStringList(Header.StitchPieceNamesSize, StitchPieceNames);
            StitchPieces = cpuFile.GetAndSkipSpan<TerrainStitchInfo>(Header.NumStitchPieces);
            cpuFile.Align2(4);

            cpuFile.ReadSizedStringList(Header.FmeshNamesSize, FmeshNames);
            cpuFile.Align2(4);

            Data = cpuFile.GetAndSkip<TerrainData>();

            u32 terrainMaterialsNameListSize = cpuFile.Read<u32>();
            cpuFile.ReadSizedStringList(terrainMaterialsNameListSize, TerrainMaterialNames);
            cpuFile.Align2(16);

            //TODO: Fix this hack
            //Hack to get to the next known piece of data
            if (cpuFile.Peek<u32>() < 1000000)
            {
                cpuFile.Skip(4);
                cpuFile.Align2(16);
            }

            cpuFile.Skip(4);
            u32 numMaterials = cpuFile.Read<u32>();
            cpuFile.Skip(28);
            cpuFile.Skip(numMaterials * 4);
            cpuFile.Align2(16);

            //TODO: Fix
            //Another hack like above
            if (cpuFile.Peek<u32>() == 0)
            {
                cpuFile.Skip(4);
                cpuFile.Align2(16);
            }

            for (int i in 0 ..< numMaterials)
            {
                RfgMaterial material = .();
                switch (material.Read(cpuFile))
                {
                    case .Ok:
                        Materials.Add(material);
                    case .Err:
                        return .Err("Failed to read material data");
                }
            }

            if (Data.ShapeHandle != 0xFFFFFFFF)
                if (SkipHavokData(cpuFile) case .Err)
                    return .Err("Read error. Invalid or unsupported RFG file format.");

            cpuFile.Align2(4);
            cpuFile.Skip(Data.NumSubzones * 4);
            if (Data.NumSidemapMaterials > 0)
            {
                cpuFile.Skip(8);
                cpuFile.Skip(Data.NumSidemapMaterials * 4 * 2);
                for (int i in 0 ..< Data.NumSidemapMaterials)
                {
                    SidemapMaterial material = new .();
                    switch (material.Read(cpuFile))
                    {
                        case .Ok:
                            SidemapMaterials.Add(material);
                        case .Err:
                            delete material;
                            return .Err("Failed to read sidemap material");
                    }
                }
            }

            //Appears to be navmesh/pathfinding data
            cpuFile.Align2(4);
            u32 maybeNumNavmeshes = cpuFile.Read<u32>();
            u32 maybeNavmeshSize = cpuFile.Read<u32>();
            cpuFile.Skip(maybeNavmeshSize - 4);
            cpuFile.Align2(16);

            if (cpuFile.Peek<u32>() == HavokSignature)
                if (SkipHavokData(cpuFile) case .Err)
                    return .Err("Read error. Invalid or unsupported RFG file format.");

            //Likely invisible barrier data
            cpuFile.Align2(4);
            cpuFile.Skip(Data.NumInvisibleBarriers * 8);
            cpuFile.Align2(16);

            if (cpuFile.Peek<u32>() == HavokSignature)
	            if (SkipHavokData(cpuFile) case .Err)
	                return .Err("Read error. Invalid or unsupported RFG file format.");

            //Todo: Determine purpose, maybe related to undergrowth/grass placement
            //Layer map data. Seems to have BitDepth * ResX * ResY bits
            cpuFile.Align2(16);
            cpuFile.Skip(Data.LayerMap.DataSize);
            cpuFile.Skip(Data.LayerMap.NumMaterials * 4);
            for (int i in 0 ..< Data.LayerMap.NumMaterials)
            {
                LayerMapMaterialNames.Add(cpuFile.ReadStrC(.. new .()));
            }
            cpuFile.Align2(4);
            cpuFile.Skip(Data.LayerMap.NumMaterials * 4);

            if (Data.NumUndergrowthLayers > 0)
            {
                //Undergrowth layer data
                UndergrowthLayers = cpuFile.GetAndSkipSpan<UndergrowthLayerData>(Data.NumUndergrowthLayers);

                int totalModels = 0;
                for (var layer in ref UndergrowthLayers)
                    totalModels += layer.NumModels;

                cpuFile.Skip(totalModels * 16);
                for (int i in 0 ..< totalModels)
                {
                    LayerMapMaterialNames2.Add(cpuFile.ReadStrC(.. new .()));
                    cpuFile.Align2(4);
                }
                cpuFile.Align2(4);
                cpuFile.Skip(16384); //TODO: Figure out what this data is

                //Undergrowth cell data
                UndergrowthCellData = cpuFile.GetAndSkipSpan<UndergrowthCellLayerData>(Data.NumUndergrowthCellLayerDatas);
                cpuFile.Align2(4);

                //More undergrowth data
                SingleUndergrowthCellData = cpuFile.GetAndSkipSpan<SingleUndergrowthCellLayerData>(Data.NumUndergrowthCellLayerDatas);

                int numSingleUndergrowths = 0;
                for (var cell in ref SingleUndergrowthCellData)
                {
					numSingleUndergrowths += cell.NumSingleUndergrowth;
                }
                SingleUndergrowthData = cpuFile.GetAndSkipSpan<SingleUndergrowthData>(numSingleUndergrowths);

                //TODO: Fix this
                //Another hack to get to the next data block
                cpuFile.Align(4);
                while (cpuFile.Peek<u32>() == 0 || cpuFile.Peek<u32>() > 1000 || cpuFile.Peek<u32>() < 5)
                	cpuFile.Skip(4);
            }
            cpuFile.Align2(4);

            u32 minimapMaterialNamesSize = cpuFile.Read<u32>();
            cpuFile.ReadSizedStringList(minimapMaterialNamesSize, MinimapMaterialNames);
            cpuFile.Align2(16);

            MinimapMaterials.Read(cpuFile);
            cpuFile.Skip(432);

            //Read mesh config
            for (int i in 0 ..< 9)
            {
                MeshDataBlock mesh = new .();
                switch (mesh.Read(cpuFile))
                {
                    case .Ok:
                        Meshes[i] = mesh;
                    case .Err(StringView err):
                        delete mesh;
                        return .Err(err);
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
            if (maybeSignature != 1212891981)
                return .Err;

            cpuFile.Skip(4);
            u32 size = cpuFile.Read<u32>();
            cpuFile.Seek(startPos + size);
            return .Ok;
        }

        //Get vertex and index buffers + their layout info. The mesh info only stays alive as long as the TerrainLowLod classes data is alive.
        public Result<MeshInstanceData, StringView> GetMeshData(int index)
        {
            if (!Loaded)
                return .Err("Mesh not loaded. You must call Terrain.Load() before calling GetMeshData()");
            if (index < 0 || index > 8)
                return .Err("Out of range index passed to Terrain.GetMeshData(). Must be in range [0, 8]");

            //Calculate mesh data offset in gpu file
            i64 meshStartPos = 0;
            for (int i in 0 ..< index)
            {
                MeshDataBlock config = Meshes[i];
                meshStartPos += config.Header.VerticesOffset + (config.Header.NumVertices * config.Header.VertexStride0);
                meshStartPos += 4; //Skip end CRC
            }

            MeshInstanceData mesh = .();
            MeshDataBlock config = Meshes[index];
            ByteSpanStream gpuFile = scope .(_gpuFileBytes);

            //Sanity check. Make sure CRCs match. If not something probably went wrong when reading/writing from packfile
            gpuFile.Seek(meshStartPos, .Absolute);
            u32 startCRC = gpuFile.Read<u32>();
            if (startCRC != config.Header.VerificationHash)
                return .Err("Start CRC mismatch in gterrain_pc file");

            //Read index buffer
            gpuFile.Seek(meshStartPos + config.Header.IndicesOffset);
            mesh.IndexBuffer = gpuFile.GetAndSkipSpan<u8>(config.Header.NumIndices * config.Header.IndexSize);

            //Read vertex buffer
            gpuFile.Seek(meshStartPos + config.Header.VerticesOffset);
            mesh.VertexBuffer = gpuFile.GetAndSkipSpan<u8>(config.Header.NumVertices * config.Header.VertexStride0);

            //Sanity check. CRC at the end of the mesh data should match the start
            u32 endCRC = gpuFile.Read<u32>();
            if (startCRC != endCRC)
	            return .Err("End CRC mismatch in gterrain_pc file");

            mesh.Config = config;
            return mesh;
        }
    }

    [CRepr, RequiredSize(20)]
    public struct TerrainStitchInfo
    {
        public Vec2<f32> Bmin;
        public Vec2<f32> Bmax;
        public u32 FilenameOffset;
    }

    [CRepr, RequiredSize(32)]
    struct TerrainLayerMap
    {
        public u32 ResX;
        public u32 ResY;
        public u32 BitDepth;
        public u32 DataSize;
        public u32 DataOffset;
        public u32 NumMaterials;
        public u32 MaterialNamesOffset;
        public u32 MaterialIndexOffset;
    }

    [CRepr, RequiredSize(1064)]
    public struct TerrainData
    {
        public Vec3<f32> Bmin;
        public Vec3<f32> Bmax;
        public u32 Xres;
        public u32 Zres;
        public u32 NumOccluders;
        public u32 OccludersOffset;
        public u32 TerrainMaterialMapOffset;
        public u32 TerrainMaterialsOffset;
        public u32 NumTerrainMaterials;
        public u32 MinimapMaterialHandle;
        public u32 MinimapMaterialOffset;
        public u32 LowLodPatchesOffset;
        public u32 LowLodMaterialOffset;
        public u32 LowLodMaterialMapOffset;
        public u32 NumSubzones;
        public u32 SubzonesOffset;
        public u32 PfDataOffset;
        public TerrainLayerMap LayerMap;
        public u32 NumUndergrowthLayers;
        public u32 UndergrowthLayersOffset;
        public u32 UndergrowthCellDataOffset;
        public u32 NumUndergrowthCellLayerDatas;
        public u32 UndergrowthCellLayerDataOffset;
        public u32 SingleUndergrowthCellLayerDataOffset;
        public u32 StitchPieceCmIndex;
        public u32 NumInvisibleBarriers;
        public u32 InvisibleBarriersOffset;
        public u32 ShapeHandle;
        public u32 NumSidemapMaterials;
        public u32 SidemapDataOffset;
        public u32 ObjectStubOffset;
        public u32 StitchPhysicsInstancesOffset;
        public u32 NumStitchPhysicsInstances;
        public u32 ObjectStubPtr;
        public u32 ObjectStubPtrPadding;
        private u8[880] _padding;
    }

    public class SidemapMaterial
    {
        public append List<String> MaterialNames ~ClearAndDeleteItems(_);
        public RfgMaterial Material;

        public Result<void> Read(ByteSpanStream stream)
        {
            u32 materialNamesSize = stream.Read<u32>();
            stream.ReadSizedStringList(materialNamesSize, MaterialNames);
            stream.Align2(16);
            return Material.Read(stream);
        }
    }

    [CRepr, RequiredSize(28)]
    public struct UndergrowthLayerData
    {
        public i32 NumModels;
        public u32 ModelsOffset;
        public f32 MaxDensity;
        public f32 MaxFadeDistance;
        public f32 MinFadeDistance;
        public i32 PlacementMethod;
        public i32 RandomSeed;
    }

    [CRepr, RequiredSize(10)]
    public struct UndergrowthCellLayerData
    {
        public u8 LayerIndex;
        public u8 Density;
        public u8[8] Bitmask;
    }

    [CRepr, RequiredSize(12)]
    public struct SingleUndergrowthCellLayerData
    {
        public u32 NumSingleUndergrowth;
        public u32 NumExtraModelsOffset;
        public u32 SingleUndergrowthOffset;
    }

    [CRepr, RequiredSize(24)]
    public struct SingleUndergrowthData
    {
        public u32 MeshIndex;
        public Vec3<f32> Position;
        public f32 Scale;
        public f32 ColorLerp;
    }
}