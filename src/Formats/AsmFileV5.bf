using System.Collections;
using System.IO;
using RfgTools;
using System;

namespace RfgTools.Formats
{
    ///V5 of the asm_pc format. Used by all versions of Red Faction Guerrilla on PC.
	public class AsmFileV5
	{
        public class Container
        {
            public String Name = new .() ~delete _;
            public ContainerType Type = .None;
            public ContainerFlags Flags = .None;
            public u16 PrimitiveCount = 0;
            public u32 DataOffset = 0;
            public u32 SizeCount = 0;
            public u32 CompressedSize = 0;

            public List<Primitive> Primitives = new .() ~DeleteContainerAndItems!(_);
            public List<u32> PrimitiveSizes = new .() ~delete _;

            public void Read(Stream stream)
            {
                //Read container metadata
                u32 nameLength = stream.Read<u16>();
                stream.ReadFixedLengthString((u64)nameLength, Name);
                Type = (ContainerType)stream.Read<u8>();
                Flags = (ContainerFlags)stream.Read<u16>();
                PrimitiveCount = stream.Read<u16>();
                DataOffset = stream.Read<u32>();
                SizeCount = stream.Read<u32>();
                CompressedSize = stream.Read<u32>();

                //Read primitive sizes
                for (int i in 0..<SizeCount)
                    PrimitiveSizes.Add(stream.Read<u32>());

                //Read primitive metadata
                for (int i in 0..<PrimitiveCount)
                {
                    Primitive primitive = new .();
                    primitive.Read(stream);
                    Primitives.Add(primitive);
                }
            }
        }

        public class Primitive
        {
            public String Name = new .() ~delete _;
            public PrimitiveType Type = .None;
            public AllocatorType Allocator = .None;
            public PrimitiveFlags Flags = .None;
            public u8 SplitExtIndex = 0;
            public i32 HeaderSize = 0;
            public i32 DataSize = 0;

            public void Read(Stream stream)
            {
                u32 nameLength = stream.Read<u16>();
                stream.ReadFixedLengthString(nameLength, Name);
                Type = (PrimitiveType)stream.Read<u8>(); //TODO: See if the enum can be used as T here instead of casting u8
                Allocator = (AllocatorType)stream.Read<u8>();
                Flags = (PrimitiveFlags)stream.Read<u8>();
                SplitExtIndex = stream.Read<u8>();
                HeaderSize = stream.Read<i32>();
                DataSize = stream.Read<i32>();
            }
        }

        public String Name = new .() ~delete _;
        public u32 Signature = 0;
        public u16 Version = 0;
        public u16 ContainerCount = 0;
        public List<Container> Containers = new .() ~DeleteContainerAndItems!(_);

        public Result<void, StringView> Read(Stream stream, StringView name)
        {
            Name.Set(name);
            Signature = stream.Read<u32>();
            Version = stream.Read<u16>();
            ContainerCount = stream.Read<u16>();
            if (Signature != 3203399405)
                return .Err("Error! Invalid asm file signature. Expected 3203399405");
            if (Version != 5) //Only have seen and reversed version 36
                return .Err("Error! Invalid asm file version. Expected 5");

            for (int i in 0..<ContainerCount)
            {
                Container container = new .();
                container.Read(stream);
                Containers.Add(container);
            }

            return .Ok;
        }
	}
}