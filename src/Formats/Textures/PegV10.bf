using Common.Misc;
using Common.IO;
using Common;
using System;

namespace RfgTools.Formats.Textures
{
    //Version 10 of texture format used in RFG. Extension = cpeg_pc|gpeg_pc and cvbm_pc|gvbm_pc
	public class PegV10
	{
        private u8[] _cpuFileDataCopy = null ~DeleteIfSet!(_);
        private u8[] _gpuFileDataCopy = null ~DeleteIfSet!(_);
        private Span<u8> _cpuFileBytes = .Empty;
        private Span<u8> _gpuFileBytes = .Empty;
        public bool Loaded { get; private set; } = false;

        public Header* Header = null;
        public Span<PegV10.Entry> Entries = .Empty;
        public char8* _entryNames = null;

        [CRepr, RequiredSize(24)]
        public struct Header
        {
            public u32 Signature;
            public u16 Version;
            public u16 Platform;
            public u32 DirectoryBlockSize;
            public u32 DataBlockSize;
            public u16 NumberOfBitmaps;
            public u16 Flags;
            public u16 NumEntries;
            public u16 AlignValue;
        }

        [CRepr, RequiredSize(48)]
        public struct Entry
        {
            public u32 DataOffset;
            public u16 Width;
            public u16 Height;
            public PegFormat Format;
            public u16 SourceWidth;
            public u16 AnimTilesWidth;
            public u16 AnimTilesHeight;
            public u16 NumFrames;
            public PegFlags Flags;
            public u32 FilenameOffset;
            public u16 SourceHeight;
            public u8 Fps;
            public u8 MipLevels;
            public u32 FrameSize;
            //These values are most likely runtime only. Next and previous may be pointers set after the cpu file is loaded into memory.
            public u32 Next;
            public u32 Previous;
            public u32[2] Cache;
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

            Header = cpuFile.GetAndSkip<PegV10.Header>();
            if (Header.Signature != 1447773511) //ASCII string "GEKV"
                return .Err("Wrong file signature detected. Expected 1447773511.");
            if (Header.Version != 10)
                return .Err("Unsupported peg version. Expected version 10.");
            if (cpuFile.Length != Header.DirectoryBlockSize)
                return .Err("Peg header size mismatch. DirectoryBlockSize of peg header must be the same size as the cpeg_pc|cvbm_pc file.");

            Entries = cpuFile.GetAndSkipSpan<PegV10.Entry>(Header.NumEntries);
            _entryNames = (char8*)cpuFile.CurrentData;

            //Update entry filename offsets
            if (Entries.Length > 0)
            {
                int entryIndex = 1;
                Entries[0].FilenameOffset = 0;
                char8* pos = _entryNames;
                while (pos < _cpuFileBytes.EndPtr)
                {
                    if (entryIndex >= Entries.Length)
                        break;

                    if (*pos == '\0')
                    {
                        Entries[entryIndex].FilenameOffset = (u32)(int)((pos + 1) - _entryNames);
                        entryIndex++;
                    }
                    pos++;
                }

                if (entryIndex < Entries.Length)
                    return .Err("Failed to update entry filename offsets");
            }

            Loaded = true;
            return .Ok;
        }

        public Result<char8*, StringView> GetEntryName(int index)
        {
            if (!Loaded)
                return .Err("Peg not loaded. Call Peg10.Load() first.");
            if (index >= Entries.Length)
                return .Err("Entry index out of range.");

            return (char8*)(_entryNames + Entries[index].FilenameOffset);
        }

        //Get pixel data for entry. The pixel data lifetime depends on whether useInplace was used when Load() was called.
        public Result<Span<u8>, StringView> GetEntryPixels(int index)
        {
            if (!Loaded)
                return .Err("Peg not loaded. Call Peg10.Load() first.");
            if (index >= Entries.Length)
                return .Err("Entry index out of range.");

            ref PegV10.Entry entry = ref Entries[index];
            ByteSpanStream gpuFile = scope .(_gpuFileBytes);
            gpuFile.Seek(entry.DataOffset);
            return Span<u8>(gpuFile.CurrentData, entry.FrameSize);
        }
	}

    public enum PegFormat : u16
    {
        None = 0,
        BM_1555 = 1,
        BM_888 = 2,
        BM_8888 = 3,
        PS2_PAL4 = 200,
        PS2_PAL8 = 201,
        PS2_MPEG32 = 202,
        PC_DXT1 = 400,
        PC_DXT3 = 401,
        PC_DXT5 = 402,
        PC_565 = 403,
        PC_1555 = 404,
        PC_4444 = 405,
        PC_888 = 406,
        PC_8888 = 407,
        PC_16_DUDV = 408,
        PC_16_DOT3_COMPRESSED = 409,
        PC_A8 = 410,
        XBOX2_DXN = 600,
        XBOX2_DXT3A = 601,
        XBOX2_DXT5A = 602,
        XBOX2_CTX1 = 603,
        PS3_DXT5N = 700,
    }

    public enum PegFlags
    {
        None = 0, // 0
        Unknown0 = 1 << 0, // 1
        Unknown1 = 1 << 1, // 2
        Unknown2 = 1 << 2, // 4
        CubeTexture = 1 << 3, // 8
        Unknown4 = 1 << 4, // 16
        Unknown5 = 1 << 5, // 32
        Unknown6 = 1 << 6, // 64
        Unknown7 = 1 << 7, // 128
        Unknown8 = 1 << 8, // 256
        Unknown9 = 1 << 9, // 512
        Unknown10 = 1 << 10, // 1024
        Unknown11 = 1 << 11, // 2048
        Unknown12 = 1 << 12, // 4096
        Unknown13 = 1 << 13, // 8192
        Unknown14 = 1 << 14, // 16384
        Unknown15 = 1 << 15, // 32768
    }
}