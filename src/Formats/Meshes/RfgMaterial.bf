using Common;
using System;
using Common.IO;
using Common.Misc;

namespace RfgTools.Formats.Meshes
{
    //Material data stored in most RFG mesh formats
	public struct RfgMaterial
	{
        public Header* Header = null;
        public Span<TextureDesc> Textures = .Empty;
        public Span<u32> ConstantNameChecksums = .Empty;
        public Span<MaterialConstant> Constants = .Empty;

        [CRepr, RequiredSize(28)]
        public struct Header
        {
            public u32 ShaderHandle;
            public u32 NameChecksum;
            public u32 MaterialFlags;
            public u16 NumTextures;
            public u8 NumConstants;
            public u8 MaxConstants;
            //TODO: See if these could be used as pointers to avoid allocating an RfgMaterial instance. Will need wrapper to convert 32bit ptr to 64bit
            public u32 TextureOffset;
            public u32 ConstantNameChecksumsOffset;
            public u32 ConstantBlockOffset;
        }

        //Read from memory stream. The backing data for the stream should stay alive as long as this struct instance is alive since its pointing directly to that data.
        public Result<void> Read(ByteSpanStream stream) mut
        {
            i64 materialDataStart = stream.Position;
            u32 materialDataSize = stream.Read<u32>();

            Header = stream.GetAndSkip<RfgMaterial.Header>();
            Textures = stream.GetAndSkipSpan<TextureDesc>(Header.NumTextures);
            ConstantNameChecksums = stream.GetAndSkipSpan<u32>(Header.NumConstants);
            stream.Align2(16);
            Constants = stream.GetAndSkipSpan<MaterialConstant>(Header.MaxConstants);
            stream.Align2(16);

            if (stream.Position != materialDataStart + materialDataSize)
                return .Err;

            return .Ok;
        }
	}

    [CRepr, RequiredSize(12)]
    public struct TextureDesc
    {
        public u32 NameOffset;
        public u32 NameChecksum;
        public u32 TextureIndex;
    }

    [CRepr, RequiredSize(16)]
    public struct MaterialConstant
    {
        public f32[4] Constants;
    }
}