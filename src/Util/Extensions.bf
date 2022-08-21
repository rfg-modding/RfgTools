using RfgTools;

namespace System.IO
{
    extension Stream
    {
        public Result<void> ReadFixedLengthString(u64 size, String output)
        {
        	for (u64 i = 0; i < size; i++)
        	{
        		char8 char;
        		char = Read<char8>();
        		output.Append(char);
        	}
        	return .Ok;
        }

        public void WriteNullBytes(u64 count)
        {
        	for(u64 i = 0; i < count; i++)
        		this.Write<u8>(0);
        }

        //Calculate amount of bytes needed to align current position with argument
        public u64 CalcAlignment(u64 alignmentValue)
        {
        	return CalcAlignment((u64)Position, alignmentValue);
        }

        public static u64 CalcAlignment(u64 position, u64 alignmentValue)
        {
        	u64 remainder = position % alignmentValue;
        	u64 paddingSize = remainder > 0 ? alignmentValue - remainder : 0;
        	return paddingSize;
        }

        //Separate Align implementation that only writes if the file access flags are set to write
        public u64 Align2(u64 alignmentValue)
        {
        	//If it's a file and we have write access use impl that can write null bytes to fulfill alignment. Otherwise don't.
        	if(this.GetType() == typeof(FileStream))
        	{
        		var file = (FileStream)this;
        		if(file.[Friend]mFileAccess & .Read != 0)
        			return AlignRead(alignmentValue);
        		else if(file.[Friend]mFileAccess & .Write != 0)
        			return AlignWrite(alignmentValue);

        		return 0;
        	}

        	return AlignRead(alignmentValue);
        }

        //Align position with target and write null bytes if necessary
        public u64 AlignWrite(u64 alignmentValue)
        {
        	u64 paddingSize = CalcAlignment(alignmentValue);
        	for(u64 i = 0; i < paddingSize; i++)
        		Write<u8>(0);

        	return paddingSize;
        }

        //Align position with target but don't write any null bytes
        public u64 AlignRead(u64 alignmentValue)
        {
        	u64 paddingSize = CalcAlignment(alignmentValue);
        	Seek(Position + (i64)paddingSize, .Absolute);

        	return paddingSize;
        }
    }
}

namespace System
{
    extension Array1<T>
    {
        public Span<u8> ToByteSpan()
        {
            return .((u8*)this.Ptr, sizeof(T) * this.Count);
        }
    }
}