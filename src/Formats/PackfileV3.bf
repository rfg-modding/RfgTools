using System.Collections;
using System.IO;
using Common;
using System;
using Zlib;
using Common.Misc;
using System.Collections;
using System;
using RfgTools.Hashing;
using System.Interop;
using Xml_Beef;
using static Zlib.Zlib;

namespace RfgTools.Formats
{
    ///Version 3 of the packfile format used by all versions of Red Faction Guerrilla (.vpp_pc and .str2_pc files)
    public class PackfileV3
    {
        [CRepr, RequiredSize(364)]
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
        public bool Compressed => Header.Compressed;
        public bool Condensed => Header.Condensed;

        public Header Header;
        public Entry[] Entries = null ~ if (_ != null) delete _;
        private char8[] _entryNames = null ~ if (_ != null) delete _;
        public List<StringView> EntryNames = new .() ~ delete _;

        public List<AsmFileV5> AsmFiles = new .() ~DeleteContainerAndItems!(_);
        private Stream _input ~ delete _;
        private u32 _dataBlockOffset = 0;
        private bool _readMetadata = false;
        private i64 _baseOffset = 0; //Used to read container headers from a non-compressed vpp_pc without fully extracting them into memory

        //Create packfile from stream
        public this(Stream input, StringView name)
        {
            _input = input;
            Name = new .()..Append(name);
        }

        //Create packfile from file
        public this(StringView path, i64 baseOffset = 0)
        {
            _input = new FileStream()..Open(path, .Read, .Read);
            Name = Path.GetFileName(path, .. new String());
            _baseOffset = baseOffset;
        }

        public Result<void, StringView> ReadMetadata()
        {
            //Read and validate header
            _input.Seek(_baseOffset);
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
        	if(condition != null && (*condition) == false)
        		return;
        }

        //Extracts subfiles to folder. Can pass it a bool that it will check periodically for an early exit signal
        public void ExtractSubfiles(StringView outputFolderPath, bool* earlyExitCondition = null, bool writeStreamsFile = true)
        {
            //Ensure we've read metadata and skip empty packfiles
            if (!_readMetadata)
                ReadMetadata();

            //Seek to data block and ensure out dir exists
            _input.Seek(_dataBlockOffset, .Absolute);
            Directory.CreateDirectory(outputFolderPath);

            //@streams.xml contains files in packfile and their order
            if (writeStreamsFile)
                WriteStreamsFile(outputFolderPath);

            if (_input.Length <= 2048)
	            return;

            //Extract subfiles. Pick method based on flags.
            if (Compressed && Condensed)
                ExtractCompressedAndCondensed(outputFolderPath, earlyExitCondition);
            else if (Compressed)
                ExtractCompressed(outputFolderPath, earlyExitCondition);
            else
                ExtractDefault(outputFolderPath, earlyExitCondition);

            return;
        }

        private void WriteStreamsFile(StringView outputFolderPath)
        {
            Xml xml = scope .();
            XmlNode streams = xml.AddChild("streams");
            streams.AttributeList.Add("endian", "Little");
            streams.AttributeList.Add("compressed", Compressed ? "True" : "False");
            streams.AttributeList.Add("condensed", Condensed ? "True" : "False");

            for (StringView entryName in EntryNames)
            {
                XmlNode entry = streams.AddChild("entry");
                entry.AttributeList.Add("name", .. scope String(entryName));
                entry.NodeValue.Set(entryName);
            }
            xml.SaveToFile(scope $@"{outputFolderPath}\@streams.xml");
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

                u8[] result = new u8[entry.DataSize];
                Internal.MemCpy(result.Ptr, outputBuffer.Ptr + entry.DataOffset, entry.DataSize);
                return result;
            }
            else if (Compressed)
            {
                //Create decompression buffers
                u8[] inputBuffer = new u8[entry.CompressedDataSize];
                u8[] outputBuffer = new u8[entry.DataSize];
                defer delete inputBuffer;

                //Seek to entry data. Compressed offset isn't stored so we calculate it by summing previous entries
                _input.Seek(_dataBlockOffset);
                for (int j in 0 ..< targetIndex)
                {
                    _input.Skip(Entries[j].CompressedDataSize);
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

        //Extract all subfiles into memory buffer. Caller is responsible for deleting the returned object on success.
        public Result<MemoryFileList, StringView> ExtractSubfilesToMemory()
        {
            if (!(Compressed && Condensed)) //This function is intended for use with str2s to avoid repeat reads and decompression. Don't need to bother with other data layouts until needed.
                return .Err("PackfileV3.ExtractSubfilesToMemory() has only been implemented for packfiles which are compressed AND condensed");

            u8[] inputBuffer = new u8[Header.CompressedDataSize];
            u8[] outputBuffer = new u8[Header.DataSize];
            defer { delete inputBuffer; }

            //Read subfile data as one large buffer and inflate it.
            _input.Seek(_dataBlockOffset);
            if (_input.TryRead(inputBuffer) case .Err)
            {
                delete outputBuffer;
                return .Err("Failed to read compressed data block");
            }
            Zlib.Inflate(inputBuffer, outputBuffer);

            //Fill subfile list
            MemoryFileList fileList = new .(outputBuffer);
            for (int i in 0 ..< Entries.Count)
            {
                var entry = ref Entries[i];
                Span<u8> entryData = .(outputBuffer.Ptr + entry.DataOffset, entry.DataSize);
                fileList.Files.Add(new .(EntryNames[i], entryData));
            }

            return fileList;
        }

        //Extended version of packfile entries used during packing
        private class WriterEntry
        {
            public PackfileV3.Entry FileEntry; //The entry metadata that gets written to the packfile (exact same data structure)
            public append String FullPath;
            public append String Filename;
            public int FileSize;
        }

        private static Result<void> ReadStreamsFile(StringView inputPath, ref bool compressed, ref bool condensed, List<WriterEntry> writerEntries)
        {
            String streamsXmlPath = scope $"{inputPath}/@streams.xml";
            if (!File.Exists(streamsXmlPath))
                return .Err;

            String text = File.ReadAllText(streamsXmlPath, .. new .());
            defer delete text;
            Xml xml = scope .();
            xml.LoadFromString(text, (i32)text.Length);

            //<streams> block should always be the root
            XmlNode streams = xml.ChildNodes[0];

            //Get flags
            XmlAttribute compressedAttribute = streams.AttributeList.Find("compressed");
            if (compressedAttribute == null)
                return .Err;

            XmlAttribute condensedAttribute = streams.AttributeList.Find("condensed");
            if (condensedAttribute == null)
                return .Err;

            compressed = (compressedAttribute.Value.Equals("true", .OrdinalIgnoreCase));
            condensed = (condensedAttribute.Value.Equals("true", .OrdinalIgnoreCase));

            //Read entries so the order is preserved. Needed for str2_pc files since the game expects cpu/gpu file pairs to be in order and to match the asm_pc order.
            XmlNodeList entries = streams.FindNodes("entry");
            defer delete entries;
            for (XmlNode entry in entries)
            {
                XmlAttribute nameAttribute = entry.AttributeList.Find("name");
                if (nameAttribute == null)
                    return .Err;

                String entryName = nameAttribute.Value;
                String entryPath = scope $"{inputPath}\\{entryName}";
                if (!File.Exists(entryPath))
                    return .Err;

                //Entry file exists. Make a new writer entry for it
                WriterEntry entry = writerEntries.Add(.. new .());
                entry.FullPath.Set(entryPath);
                entry.Filename.Set(entryName);
                entry.FileSize = File.GetFileSize(entryPath);
            }

            return .Ok;
        }

        public static Result<void> Pack(StringView inputPath, StringView outputPath, bool preferCompressed, bool preferCondensed)
        {
            if (!Directory.Exists(inputPath))
            {
                return .Err;
            }
            Directory.CreateDirectory(Path.GetDirectoryPath(outputPath, .. scope .()));

            bool compressed = preferCompressed;
            bool condensed = preferCondensed;
            u32 curNameOffset = 0;
            u32 curDataOffset = 0;
            u32 totalDataSize = 0;
            u32 totalNamesSize = 0;

            FileStream output = new .()..Open(outputPath, mode: .OpenOrCreate, access: .Write, share: .None, bufferSize: 1000000);
            List<WriterEntry> entries = new .();
            defer delete output;
            defer { DeleteContainerAndItems!(entries); }

            String outputExtension = Path.GetExtension(outputPath, .. scope .());
            bool isStr2 = (outputExtension == ".str2_pc");
            bool usingStreamsFile = isStr2 || File.Exists(scope $@"{inputPath}\@streams.xml");
            if (usingStreamsFile)
            {
                if (ReadStreamsFile(inputPath, ref compressed, ref condensed, entries) case .Err)
	                return .Err;
            }

            //Get a list of input files if @streams.xml isn't used
            if (!usingStreamsFile)
            {
                for (var file in Directory.EnumerateFiles(inputPath))
                {
                    if (file.IsDirectory)
                        continue;
                    if (file.GetFileName(.. scope .()) == "@streams.xml")
                        continue;

                    WriterEntry entry = entries.Add(.. new .());
                    file.GetFilePath(entry.FullPath);
                    file.GetFileName(entry.Filename);
                    entry.FileSize = file.GetFileSize();
                }
            }

            //Create for each input file & calculate size + offset values
            for (WriterEntry entry in entries)
            {
                entry.FileEntry = .()
				{
					NameOffset = curNameOffset,
                    DataOffset = curDataOffset,
                    NameHash = Hash.HashVolition(entry.Filename),
                    DataSize = (u32)entry.FileSize,
                    CompressedDataSize = compressed ? 0 : u32.MaxValue
				};

                curNameOffset += (u32)entry.Filename.Length + 1;
                curDataOffset += (u32)entry.FileSize;
                totalDataSize += (u32)entry.FileSize;
                totalNamesSize += (u32)entry.Filename.Length + 1;

                if (compressed && condensed && entry != entries.Back && !isStr2)
                {
                    curDataOffset += (u32)Stream.CalcAlignment(curDataOffset, 16);
                    totalDataSize += (u32)Stream.CalcAlignment(totalDataSize, 16);
                }
                else if (!condensed)
                {
                    curDataOffset += (u32)Stream.CalcAlignment(curDataOffset, 2048);
                }
            }

            Header.HeaderFlags packfileFlags = 0;
            if (compressed)
                packfileFlags |= .Compressed;
            if (condensed)
                packfileFlags |= .Condensed;

            //Set header values that we know. Some can't be known until the whole file is written.
            Header header = .()
            {
                Signature = 0x51890ACE,
                Version = 3,
                ShortName = "",
                PathName = "",
                Flags = packfileFlags,
                NumSubfiles = (u32)entries.Count,
                FileSize = 0, //Not yet known, set after writing file data. Includes padding
                EntryBlockSize = (u32)entries.Count * 28, //Doesn't include padding
                NameBlockSize = totalNamesSize, //Doesn't include padding
                DataSize = (compressed && condensed) ? totalDataSize : 0, //Includes padding
                CompressedDataSize = compressed ? 0 : 0xFFFFFFFF, //Not known, set to 0xFFFFFFFF if not compressed
            };

            //Calc data start and skip to it's location. We'll circle back and write header + entries at the end when he have all stats
            u32 dataStart = 0;
            dataStart += 2048; //Header size
            dataStart += (u32)entries.Count * 28; //Each entry is 28 bytes
            dataStart += (u32)Stream.CalcAlignment(dataStart, 2048); //Align(2048) after end of entries
            dataStart += totalNamesSize; //Filenames list
            dataStart += (u32)Stream.CalcAlignment(dataStart, 2048); //Align(2048) after end of file names
            output.WriteNullBytes((u64)(dataStart - output.Position));

            //Note: This code could probably be cleaned up quite a bit more. It's basically a straight port form the C++ version since I didn't want to break packfile packing (difficult to debug)
            //Write subfile data
            if (entries.Count > 0)
            {
                if (compressed && condensed)
                {
                    ZStream deflateStream = .()
                    {
                        ZAlloc = null,
                        ZFree = null,
                        Opaque = null,
                        AvailIn = 0,
                        NextIn = null,
                        AvailOut = 0,
                        NextOut = null
                    };
                    Zlib.DeflateInit(&deflateStream, isStr2 ? .BestCompression : .BestSpeed);

                    c_ulong lastOut = 0;
                    u64 tempDataOffset = 0;
                    for (WriterEntry entry in entries)
                    {
                        List<u8> bytes = File.ReadAll(entry.FullPath, .. new .());
                        defer delete bytes;
                        tempDataOffset += (u64)bytes.Count;

                        //Add align(16) null bytes after uncompressed data. Not added to entry.DataSize but necessary for compression for some reason
                        if (entry != entries.Back && !isStr2)
                        {
                            u32 alignPad = (u32)Stream.CalcAlignment(tempDataOffset, 16);
                            if (alignPad != 0)
                            {
                                tempDataOffset += alignPad;
                                for (u32 j = 0; j < alignPad; j++)
                                {
                                    bytes.Add(0);
                                }
                            }
                        }

                        c_ulong deflateUpperBound = Zlib.DeflateBound(&deflateStream, (c_ulong)bytes.Count);
                        u8[] compressedBytes = new u8[deflateUpperBound];
                        defer delete compressedBytes;

                        deflateStream.NextIn = bytes.Ptr;
                        deflateStream.AvailIn = (u32)bytes.Count;
                        deflateStream.NextOut = compressedBytes.Ptr;
                        deflateStream.AvailOut = deflateUpperBound;
                        Zlib.Deflate(&deflateStream, .SyncFlush);

                        c_ulong entryCompressedSize = deflateStream.TotalOut - lastOut;
                        entry.FileEntry.CompressedDataSize = entryCompressedSize;
                        header.CompressedDataSize += entryCompressedSize;

                        output.Write(Span<u8>(compressedBytes.Ptr, (int)entryCompressedSize));
                        lastOut = deflateStream.TotalOut;
                    }

                    Zlib.DeflateEnd(&deflateStream);
                }
                else if (compressed)
                {
                    for (WriterEntry entry in entries)
                    {
                        //Read subfile data and compress it
                        List<u8> bytes = File.ReadAll(entry.FullPath, .. new .());
                        defer delete bytes;

                        var deflateResult = Zlib.Deflate(bytes, .BestSpeed);
                        if (deflateResult case .Err(ZlibResult err))
                        {
                            //TODO: Add logging function to RfgTools which accepts callbacks so it can be hooked into the Nanoforge logger/error handling
                            return .Err;
                        }
                        var compressedData = deflateResult.Get();
                        defer delete compressedData.Buffer;

                        //Write compressed data to file
                        output.Write(Span<u8>(compressedData.Buffer.Ptr, (int)compressedData.DataSize));

                        //Update data sizes
                        entry.FileEntry.CompressedDataSize = (u32)compressedData.DataSize;
                        header.CompressedDataSize += (u32)compressedData.DataSize;
                        header.DataSize += entry.FileEntry.DataSize;

                        //Add alignment padding for all except final entry
                        if (entry != entries.Back)
                        {
                            u32 padSize = (u32)output.AlignWrite(2048);
                            u32 uncompressedPad = (u32)Stream.CalcAlignment(header.DataSize, 2048);
                            header.DataSize += uncompressedPad; //header.DataSize is calculated the same way even when compressed
                            header.CompressedDataSize += padSize;
                        }
                    }
                }
                else
                {
                    for (WriterEntry entry in entries)
                    {
                        List<u8> bytes = File.ReadAll(entry.FullPath, .. new .());
                        defer delete bytes;
                        output.Write(Span<u8>(bytes.Ptr, bytes.Count));
                        header.DataSize += entry.FileEntry.DataSize;

                        //There's no padding bytes if the packfile is condensed or after the final entry
                        if (!condensed && entry != entries.Back)
                            header.DataSize += (u32)output.AlignWrite(2048);
                    }
                }
            }

            //Write header
            header.FileSize = (u32)output.Length;
            output.Flush();
            output.Seek(0);
            output.Write(header);
            output.AlignWrite(2048);

            //Write entry metadata. They're written manually since the internal representation doesn't match the file representation exactly.
            for (WriterEntry entry in entries)
            {
                output.Write<u32>(entry.FileEntry.NameOffset);
                output.WriteNullBytes(4);
                output.Write<u32>((u32)entry.FileEntry.DataOffset);
                output.Write<u32>(entry.FileEntry.NameHash);
                output.Write<u32>(entry.FileEntry.DataSize);
                output.Write<u32>(entry.FileEntry.CompressedDataSize);
                output.WriteNullBytes(4);
            }
            output.AlignWrite(2048);

            //Write entry names
            for (WriterEntry entry in entries)
            {
                output.Write(entry.Filename);
                output.Write('\0'); //Need null terminator
            }
            output.AlignWrite(2048);
            output.Flush();

            return .Ok;
        }
    }

    public class MemoryFileList
    {
        private u8[] _data ~delete _;
        public append List<MemoryFile> Files ~ClearAndDeleteItems(_);

        public this(u8[] data)
        {
            _data = data;
        }

        public class MemoryFile
        {
            public append String Name;
            public readonly Span<u8> Data;

            public this(StringView name, Span<u8> data)
            {
                Name.Set(name);
                Data = data;
            }
        }
    }
}