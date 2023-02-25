using System.Collections;
using System.IO;
using Common;
using System;
using Zlib;

namespace RfgTools.Formats
{
    ///Version 3 of the packfile format used by all versions of Red Faction Guerrilla (.vpp_pc and .str2_pc files)
    public class PackfileV3
    {
        [CRepr]
        public struct Header
        {
            public enum HeaderFlags : u32
            {
                None = 0,
                Compressed = 1,
                Condensed = 2
            }

            public u32 Signature = 0; //Magic signature to identify packfiles. Should be 1367935694 (0xCE0A8951)
            public u32 Version = 0; //Format version. Should be 3
            public char8[65] ShortName; //Unused data section. Used by gibbed's unpacker so leaving it open for reading here
            public char8[256] PathName; //Unused data section. Used by gibbed's unpacker so leaving it open for reading here
            public u8[3] Pad1; //Alignment padding. Value does not matter
            public HeaderFlags Flags = HeaderFlags.None; //Format flags. Describes the format and layout of the data block
            public u8[4] Junk1; //Junk for our purposes. Set by game at runtime
            public u32 NumSubfiles = 0; //The number of subfiles in this packfile
            public u32 FileSize = 0; //The total size in bytes of the packfile
            public u32 EntryBlockSize = 0; //The size of the entry block in bytes. Includes padding bytes
            public u32 NameBlockSize = 0; //The size of the names block in bytes. Includes padding bytes
            public u32 DataSize = 0; //The size of the data block in bytes. Includes padding bytes. If the vpp is compressed this refers to the size after decompression
            public u32 CompressedDataSize = 0; //The size of the data block compressed data in bytes. Includes padding bytes. Equals 0xFFFFFFFF if packfile isn't compressed
            //Followed by 12 bytes of junk data and 1668 bytes of padding (to align(2048))

            public bool Compressed => (Flags & HeaderFlags.Compressed) == HeaderFlags.Compressed;
            public bool Condensed => (Flags & HeaderFlags.Condensed) == HeaderFlags.Condensed;
        }

        //This struct doesn't perfectly match whats in the files. Needed to increase DataOffset from a u32 to a u64 so tools can have the correct data offset in packfiles > 4GB
        public struct Entry
        {
            public u32 NameOffset = 0; //Offset of name in subfile name list
            public u8[4] Junk1; //Junk data we don't need. Set by game at runtime
            public u64 DataOffset = 0; //Offset of uncompressed data of the entry from the start of the data block
            public u32 NameHash = 0; //Hash of the entries filename
            public u32 DataSize = 0; //Size of the entries uncompressed data
            public u32 CompressedDataSize = 0; //Size of the entries compressed data
            public u8[4] Junk2; //More data that is junk for our purposes

            public void ReadBinary(Stream input) mut
            {
                NameOffset = input.Read<u32>();
                input.Skip(4);
                DataOffset = (u64)input.Read<u32>();
                NameHash = input.Read<u32>();
                DataSize = input.Read<u32>();
                CompressedDataSize = input.Read<u32>();
                input.Skip(4);
            }
        }

        public String Name = null ~ if (Name != null) delete _;
        public bool Compressed = Header.Compressed;
        public bool Condensed = Header.Condensed;

        public Header Header;
        public Entry[] Entries = null ~ if (_ != null) delete _;
        private char8[] _entryNames = null ~ if (_ != null) delete _;
        public List<StringView> EntryNames = new .() ~ delete _;

        public List<AsmFileV5> AsmFiles = new .() ~DeleteContainerAndItems!(_);
        private Stream _input ~ delete _;
        private u32 _dataBlockOffset = 0;
        private bool _readMetadata = false;

        //Create packfile from stream
        public this(Stream input, String name)
        {
            _input = input;
            Name = name;
        }

        //Create packfile from file
        public this(StringView path)
        {
            _input = new FileStream()..Open(path, .Read);
            Name = Path.GetFileName(path, .. new String());
        }

        public Result<void, StringView> ReadMetadata()
        {
            //Read and validate header
            if (_input.TryRead(.((u8*)&Header, sizeof(Header))) case .Err)
                return .Err("Failed to read packfile header.");
            if (Header.Signature != 1367935694)
                return .Err("Error! Invalid packfile signature detected. Expected 1367935694");
            if (Header.Version != 3)
                return .Err("Error! Invalid packfile version detected. Expected 3");
            _input.Align2(2048);

            //Read entries
            Entries = new Entry[Header.NumSubfiles];
            for (int i in 0 ..< Header.NumSubfiles)
                Entries[i].ReadBinary(_input);
            _input.Align2(2048);

            //Read entry names
            _entryNames = new char8[Header.NameBlockSize];
            if (_input.TryRead(_entryNames.ToByteSpan()) case .Err)
                return .Err("Failed to read packfile entry names.");

            //Make a string view for each entry name for easy access
            for (Entry entry in Entries)
            {
                char8* str = _entryNames.Ptr + entry.NameOffset;
                EntryNames.Add(.(str));
            }

            //Fix offsets. They can be incorrect for packfiles larger than 4GB since the game uses a 32bit int for the offset
            FixEntryDataOffsets();

            //Align to data clock and store it's offset for extraction
            _input.Align2(2048);
            _dataBlockOffset = (u32)_input.Position;
            _readMetadata = true;

            return .Ok;
        }

        //Used by extraction functions so extraction can be stopped early
        private mixin ExitCheck(bool* condition)
        {
        	if((*condition) == false)
        		return;
        }

        //Extracts subfiles to folder. Can pass it a bool that it will check periodically for an early exit signal
        public void ExtractSubfiles(StringView outputFolderPath, bool* earlyExitCondition = null)
        {
            //Ensure we've read metadata and skip empty packfiles
            if (!_readMetadata)
                ReadMetadata();
            if (_input.Length <= 2048)
                return;

            //Seek to data block and ensure out dir exists
            _input.Seek(_dataBlockOffset, .Absolute);
            Directory.CreateDirectory(outputFolderPath);

            //Extract subfiles. Pick method based on flags.
            if (Compressed && Condensed)
                ExtractCompressedAndCondensed(outputFolderPath, earlyExitCondition);
            else if (Compressed)
                ExtractCompressed(outputFolderPath, earlyExitCondition);
            else
                ExtractDefault(outputFolderPath, earlyExitCondition);

            return;
        }

        //Extract subfiles that are both compressed and condensed. Files are stored in one large compressed data blob in this format.
        private void ExtractCompressedAndCondensed(StringView outputFolderPath, bool* earlyExitCondition = null)
        {
            //Create decompression buffers
            u8[] inputBuffer = new u8[Header.CompressedDataSize];
            u8[] outputBuffer = new u8[Header.DataSize];
            defer delete inputBuffer;
            defer delete outputBuffer;

            //Read subfile data as one large buffer and inflate it.
            _input.TryRead(inputBuffer);
            ExitCheck!(earlyExitCondition);
            Zlib.Inflate(inputBuffer, outputBuffer);
            ExitCheck!(earlyExitCondition);

            //Write inflated subfiles to output folder
            u32 index = 0;
            for (var entry in ref Entries)
            {
                ExitCheck!(earlyExitCondition);
                Directory.CreateDirectory(outputFolderPath);
                File.WriteAll(scope $"{outputFolderPath}"..Append(EntryNames[index]), Span<u8>(outputBuffer.CArray() + entry.DataOffset, entry.DataSize));
                index++;
            }
        }

        //Extract subfiles that are compressed but not condensed
        private void ExtractCompressed(StringView outputFolderPath, bool* earlyExitCondition = null)
        {
            //Read each subfile from packfile, inflate data, write to output folder
            u32 index = 0;
            for (var entry in ref Entries)
            {
                //Create decompression buffers
                u8[] inputBuffer = new u8[entry.CompressedDataSize];
                u8[] outputBuffer = new u8[entry.DataSize];
                defer delete inputBuffer;
                defer delete outputBuffer;

                //Read compressed file data into buffer and align to next file
                _input.TryRead(inputBuffer);
                _input.Align2(2048);
                ExitCheck!(earlyExitCondition);

                //Decompress file data and write to file
                Zlib.Inflate(inputBuffer, outputBuffer);
                Directory.CreateDirectory(outputFolderPath);
                File.WriteAll(scope $"{outputFolderPath}"..Append(EntryNames[index]), Span<u8>(outputBuffer));
                ExitCheck!(earlyExitCondition);

                index++;
            }
        }

        //Extract non-compressed subfiles
        private void ExtractDefault(StringView outputFolderPath, bool* earlyExitCondition = null)
        {
            //Read each subfile from packfile and write to output directory
            u32 index = 0;
            for (var entry in ref Entries)
            {
                u8[] buffer = new u8[entry.DataSize];
                defer delete buffer;
                _input.Seek((i64)_dataBlockOffset + (i64)entry.DataOffset, .Absolute);
                _input.TryRead(buffer);
                Directory.CreateDirectory(outputFolderPath);
                File.WriteAll(scope $"{outputFolderPath}/"..Append(EntryNames[index]), Span<u8>(buffer));
                ExitCheck!(earlyExitCondition);

                index++;
            }
        }

        //Attempts to extract single file. If it succeeds the user must free the returned Span<u8>
        //Will attempt to extract single file.
        //If the packfile is C&C it will have to extract all subfiles and pull the target. Making it slower for those types.
        public Result<u8[], StringView> ReadSingleFile(StringView name)
        {
            if (!_readMetadata)
                ReadMetadata();

            u32 targetIndex = 0xFFFFFFFF;
            u32 i = 0;
            for (var entryName in EntryNames)
            {
                if (StringView.Compare(entryName, name) == 0)
                {
                    targetIndex = i;
                    break;
                }
                i++;
            }
            if (targetIndex == 0xFFFFFFFF)
                return .Err("ReadSingleFile failed to find target file in packfile");

            //Get target data. Extraction method depends on data format flags
            var entry = ref Entries[targetIndex];
            if (Compressed && Condensed)
            {
                //Create decompression buffers
                u8[] inputBuffer = new u8[Header.CompressedDataSize];
                u8[] outputBuffer = new u8[Header.DataSize];
                defer delete inputBuffer;
                defer delete outputBuffer;

                //Read subfile data as one large buffer and inflate it.
                _input.Seek(_dataBlockOffset);
                _input.TryRead(inputBuffer);
                Zlib.Inflate(inputBuffer, outputBuffer);

                return outputBuffer;
            }
            else if (Compressed)
            {
                //Create decompression buffers
                u8[] inputBuffer = new u8[entry.CompressedDataSize];
                u8[] outputBuffer = new u8[entry.DataSize];
                defer delete inputBuffer;

                //Seek to entry data. Compressed offset isn't stored so we calculate it by summing previous entries
                _input.Seek(_dataBlockOffset);
                for (var entry2 in ref Entries)
                {
                    _input.Skip(entry2.CompressedDataSize);
                    _input.Align2(2048);
                }

                //Read compressed data into buffer and inflate
                _input.TryRead(inputBuffer);
                Zlib.Inflate(inputBuffer, outputBuffer);
                return outputBuffer;
            }
            else
            {
                //Seek to target and read into buffer
                u8[] outputBuffer = new u8[entry.DataSize];
                _input.Seek((i64)_dataBlockOffset + (i64)entry.DataOffset);
                _input.TryRead(outputBuffer);
                return outputBuffer;
            }
        }

        public bool Contains(StringView subfileName)
        {
            for (StringView entryName in EntryNames)
                if (entryName.Equals(subfileName, true))
                    return true;

            return false;
        }

        //Fix data offsets. Values in packfile not always valid.
        //Ignores packfiles that are compressed AND condensed since those must
        //be fully extracted and data offsets aren't relevant in that case.
        private void FixEntryDataOffsets()
        {
            if (Compressed && Condensed)
                return;

            u64 runningDataOffset = 0; //Track relative offset from data section start
            for (var entry in ref Entries)
            {
                //Set entry offset
                entry.DataOffset = runningDataOffset;

                //Update offset based on entry size and storage type
                if (Compressed) //Compressed, not condensed
                {
                    runningDataOffset += (u64)entry.CompressedDataSize;
                    u64 alignmentPad = FileStream.CalcAlignment(runningDataOffset, 2048);
                    runningDataOffset += alignmentPad;
                }
                else //Not compressed, maybe condensed
                {
                    runningDataOffset += (u64)entry.DataSize;
                    if (!Condensed)
                    {
                        u64 alignmentPad = FileStream.CalcAlignment(runningDataOffset, 2048);
                        runningDataOffset += alignmentPad;
                    }
                }
            }
        }

        public Result<void, StringView> ReadAsmFiles()
        {
            if (!_readMetadata)
                ReadMetadata();

            for (int i in 0..<Entries.Count)
            {
                StringView name = EntryNames[i];
                if (Path.GetExtension(name, .. scope .()) != ".asm_pc")
                    continue;
                Result<u8[], StringView> readResult = ReadSingleFile(name);
                if (readResult case .Err(let err))
                    return .Err(err);

                defer delete readResult.Value;
                List<u8> bytes = new .(readResult.Value); //Have to make it list because the current MemoryStream constructor doesn't take Span<u8>
                Stream stream = new MemoryStream(bytes, true);
                defer delete stream;
                AsmFileV5 asmFile = new .();
                if (asmFile.Read(stream, name) case .Err(let err))
                    return .Err(err);

                AsmFiles.Add(asmFile);
            }

            return .Ok;
        }
    }
}