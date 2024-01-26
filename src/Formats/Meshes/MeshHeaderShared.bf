using Common;
using System;
using Common.Misc;

namespace RfgTools.Formats.Meshes
{
    [CRepr, RequiredSize(48)]
	public struct MeshHeaderShared
	{
        public u32 Signature;
        public u32 Version;
        public u32 MeshOffset;
        private u32 _padding0;
        public u32 MaterialMapOffset;
        private u32 _padding1;
        public u32 MaterialsOffset;
        private u32 _padding2;
        public u32 NumMaterials;
        private u32 _padding3;
        public u32 TextureNamesOffset;
        private u32 _padding4;
	}
}