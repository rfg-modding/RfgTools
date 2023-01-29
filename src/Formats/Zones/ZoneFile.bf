namespace RfgTools.Formats.Zones;
using Common.Math;
using RfgTools;
using System;

//Use to read data from RFG rfgzone_pc and layer_pc files
public class ZoneFile36
{
#region subtypes
    [CRepr]
    public struct Header
    {
        public u32 Signature;
        public u32 Version;
        public u32 NumObjects;
        public u32 NumHandles;
        public u32 DistrictHash;
        public u32 DistrictFlags;
    }

    [CRepr]
    public struct RelationData
    {
        u8[4] Padding0;
        u16 Free;
        u16[7280] Slot;
        u16[7280] Next;
        u8[2] Padding1;
        u32[7280] Keys;
        u32[7280] Values;
    };

    //Compile time size checks. Memory layouts of these must match RFG files. Use [CRepr] as well just in case so padding isn't moved around
    [OnCompile(.TypeInit)]
    private static void TypeSizeChecks()
    {
        Runtime.Assert(sizeof(Header) == 24, "sizeof(ZoneFile.Header) must be 24 bytes to match RFG zone file format.");
        Runtime.Assert(sizeof(RelationData) == 87368, "sizeof(ZoneFile.RelationData) must be 87368 bytes to match RFG zone file format.");
        Runtime.Assert(sizeof(ZoneObject) == 56, "sizeof(ZoneObject) must be 56 bytes to match RFG zone file format.");
        Runtime.Assert(sizeof(ZoneObject.Property) == 8, "sizeof(ZoneObject.Property) must be 8 bytes to match RFG zone file format.");
    }
#endregion subtypes

    private u8[] _data ~if (_data != null) delete _; //All file data is loaded into this.
    private ZoneObject* _objects = null; //Array of zone objects. Private since it's a pain to use. Use enumerators and array indexors instead.
    private u32 _objectsSize = 0;

    public Header* Header = null;
    public RelationData* RelationData = null;
    public bool Empty => Header == null || Header.NumObjects == 0 || _objects == null || _objectsSize == 0;

    //Parse zone file. If useInPlace is true bytes must stay alive for the duration of the ZoneFiles lifetime.
    //useInPlace allows you to use a pre-existing array instead of making a copy. Used in Nanoforge ZoneImporter to avoid duplicating an array of bytes read from a packfile.
    public Result<void, StringView> Load(Span<u8> bytes, bool useInPlace = false)
    {
        u8* start = bytes.Ptr;
        u8* end = bytes.EndPtr;

        //Make a copy of the data so it stays alive as long as the ZoneFile
        if (!useInPlace)
        {
			_data = new u8[bytes.Length];
            Internal.MemCpy(&_data[0], bytes.Ptr, bytes.Length);
            start = _data.ToByteSpan().Ptr;
            end = _data.ToByteSpan().EndPtr;
		}
        u8* pos = start;

        //Store header ptr
        Header = (Header*)start;
        pos += sizeof(Header);

        //Check if this format is supported
        if (Header.Signature != 1162760026)
            return .Err("Unexpected zone file signature.");
        if (Header.Version != 36)
            return .Err("Unexpected zone file version.");

        //Store relationa data ptr
        bool hasRelationData = (Header.DistrictFlags & 5) == 0;
        if (hasRelationData)
        {
            RelationData = (RelationData*)pos;
            pos += sizeof(RelationData);
        }

        //Store objects list ptr
        if (Empty)
        {
            _objects = null;
            _objectsSize = 0;
        }
        else
        {
            _objects = (ZoneObject*)pos;
            _objectsSize = (u32)(end - pos);
        }

        return .Ok;
    }
}

[CRepr]
public struct ZoneObject
{
    public u32 ClassnameHash;
    public u32 Handle;
    public Vec3<f32> Bmin;
    public Vec3<f32> Bmax;
    public u16 Flags;
    public u16 BlockSize;
    public u32 Parent;
    public u32 Sibling;
    public u32 Child;
    public u32 Num;
    public u16 NumProps;
    public u16 PropBlockSize;

    [CRepr]
    public struct Property
    {
        public u16 Type;
        public u16 Size;
        public u32 NameHash;
    }
}