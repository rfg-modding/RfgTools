#pragma warning disable 168
using Common;
using System;
using Common.IO;
using Common.Misc;
using Common.Math;
using System.Collections;

namespace RfgTools.Formats.Meshes
{
    //For rig_pc files
	public class AnimRig
	{
        private u8[] _fileDataCopy = null ~DeleteIfSet!(_);
        private Span<u8> _fileBytes = .Empty;
        public bool Loaded { get; private set; } = false;

        public Header* Header;
        public Span<u32> BoneChecksums;
        public Span<AnimBone> Bones;
        public Span<AnimTag> Tags;
        public append List<StringView> BoneNames;
        public append List<StringView> TagNames;

        [CRepr, RequiredSize(64)]
        public struct Header
        {
            public char8[32] Name; //Note: This isn't set in any vanilla files. Likely set by the game at runtime.
            public u32 Flags;
            public i32 NumBones;
            public i32 NumCommonBones;
            public i32 NumVirtualBones;
            public i32 NumTags;
            public i32 BoneNameChecksumsOffset;
            public i32 BonesOffset;
            public i32 TagsOffset;
        }

        [CRepr, RequiredSize(36)]
        public struct AnimBone
        {
            public i32 NameOffset;
            public Vec3 InvTranslation;
            public Vec3 RelBoneTranslation;
            public i32 ParentIndex;
            public i32 Vid;
        }

        [CRepr, RequiredSize(60)]
        public struct AnimTag
        {
            public i32 NameOffset;
            public Mat3 Rotation;
            public Vec3 Translation;
            public i32 ParentIndex;
            public i32 Vid;
        }

        public Result<void, StringView> Load(Span<u8> rigFileBytes, bool useInPlace = false)
        {
            if (useInPlace)
            {
                //Keep reference to the spans. They must stay alive as long as this class for things to work correctly
                _fileBytes = rigFileBytes;
            }
            else
            {
                //Make a copy of the data so it stays alive as long as the object
                _fileDataCopy = new u8[rigFileBytes.Length];
                Internal.MemCpy(&_fileDataCopy[0], rigFileBytes.Ptr, rigFileBytes.Length);
                _fileBytes = _fileDataCopy;
            }
            ByteSpanStream file = scope .(_fileBytes);

            Header = file.GetAndSkip<Header>();
            if (Header.BoneNameChecksumsOffset != 0 || Header.BonesOffset != 0 || Header.TagsOffset != 0)
            {
                //Note: All rigs examined so far have zero for these. If a non zero offset is encountered I want it to fail so I can manually verify that the offset works as expected
                return .Err("Unexpected non zero offset when 0 is expected.");
            }

            BoneChecksums = file.GetAndSkipSpan<u32>(Header.NumBones);
            Bones = file.GetAndSkipSpan<AnimBone>(Header.NumBones);
            Tags = file.GetAndSkipSpan<AnimTag>(Header.NumTags);

            readonly int namesBaseOffset = file.Position;
            for (AnimBone bone in Bones)
            {
                file.Seek(namesBaseOffset + bone.NameOffset);
                BoneNames.Add(file.ReadNullTerminatedStringView());
            }
            for (AnimTag tag in Tags)
            {
                file.Seek(namesBaseOffset + tag.NameOffset);
                TagNames.Add(file.ReadNullTerminatedStringView());
            }

            return .Ok;
        }
	}
}