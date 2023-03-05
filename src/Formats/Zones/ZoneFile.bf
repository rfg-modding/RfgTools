namespace RfgTools.Formats.Zones;
using System.Collections;
using RfgTools.Hashing;
using Common.Math;
using Common;
using System;
using RfgTools.Types;
using Common.Misc;

//Use to read data from RFG rfgzone_pc and layer_pc files
public class ZoneFile36
{
    private u8[] _data ~if (_data != null) delete _; //All file data is loaded into this if Read() is called with useInPlace = false
    private RfgZoneObject* _firstObject = null; //Array of zone objects. Private so people use the more convenient and less error enumerator + get functions
    private RfgZoneObject* _lastObject = null;
    private u32 _objectsSize = 0;

    public Header* Header = null;
    public RelationData* RelationData = null;
    public bool Empty => Header == null || Header.NumObjects == 0 || _firstObject == null || _objectsSize == 0;
    public ZoneObjectEnumerator Objects => .(_firstObject, _lastObject);

    public StringView DistrictName => Header != null ? HashDictionary.FindOriginString(Header.DistrictHash).GetValueOrDefault("Unknown") : "Unknown";

#region subtypes
    [CRepr, RequiredSize(24)]
    public struct Header
    {
        public u32 Signature;
        public u32 Version;
        public u32 NumObjects;
        public u32 NumHandles;
        public u32 DistrictHash;
        public u32 DistrictFlags;
    }

    [CRepr, RequiredSize(87368)]
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
#endregion subtypes

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
        if (Header == null || Header.NumObjects == 0)
        {
            _firstObject = null;
            _objectsSize = 0;
        }
        else
        {
            _firstObject = (RfgZoneObject*)pos;
            _objectsSize = (u32)(end - pos);
        }

        //Find last object
        u8* current = (u8*)_firstObject;
        for (int i = 0; i < Header.NumObjects - 1; i++)
        {
            current += sizeof(RfgZoneObject) + ((RfgZoneObject*)current).PropBlockSize;
        }
        _lastObject = (RfgZoneObject*)current;

        return .Ok;
    }

    public Result<RfgZoneObject*> GetObject(int index)
    {
        if (Header == null || _firstObject == null || index >= Header.NumObjects)
            return .Err;

        return _firstObject + index;
    }

    public struct ZoneObjectEnumerator : IEnumerator<RfgZoneObject*>
    {
        private int _index = 0;
        private RfgZoneObject* _curObject = null;
        private RfgZoneObject* _lastObject = null;

        public this(RfgZoneObject* firstObject, RfgZoneObject* lastObject)
        {
            _curObject = firstObject;
            _lastObject = lastObject;
        }

        public Result<RfgZoneObject*> GetNext() mut
        {
            if (_curObject == _lastObject)
                return .Err;
            if (_index == 0)
            {
                _index++;
                return _curObject;
            }    

            u8* posBytes = (u8*)_curObject;
            posBytes += sizeof(RfgZoneObject); //Jump past header
            posBytes += _curObject.PropBlockSize; //Jump past properties
            _curObject = (RfgZoneObject*)posBytes;
            _index++;
            return _curObject;
        }
    }
}

[CRepr, RequiredSize(56)]
public struct RfgZoneObject
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

    public PropertyEnumerator Properties mut => .(FirstProperty(), NumProps);
    public StringView Classname => HashDictionary.FindOriginString(ClassnameHash).GetValueOrDefault("UnknownClassname");
    public static u32 InvalidHandle => 0xFFFFFFFF;

    private Property* FirstProperty() mut
    {
        u8* pos = (u8*)&this;
        pos += sizeof(RfgZoneObject);
        Property* firstProp = (Property*)pos;
        return firstProp;
    }

    private Result<T> GetPropertyInternal<T>(StringView name, u16 type) mut
    {
        readonly u32 nameHash = Hash.HashVolitionCRC(name, 0);
        for (Property* prop in Properties)
        {
            if (prop.NameHash == nameHash)
            {
                if (prop.Type != type)
                    return .Err;
                if (prop.Size != sizeof(T))
                    return .Err;

                return *(T*)prop.Data;
            }
        }

        return .Err;
    }

    public Result<f32> GetF32(StringView name) mut
    {
        return GetPropertyInternal<f32>(name, 5);
    }

    public Result<i32> GetI32(StringView name) mut
    {
        return GetPropertyInternal<i32>(name, 5);
    }

    public Result<u32> GetU32(StringView name) mut
    {
        return GetPropertyInternal<u32>(name, 5);
    }

    public Result<i16> GetI16(StringView name) mut
    {
        return GetPropertyInternal<i16>(name, 5);
    }

    public Result<u8> GetU8(StringView name) mut
    {
        return GetPropertyInternal<u8>(name, 5);
    }

    public Result<u16> GetU16(StringView name) mut
    {
        return GetPropertyInternal<u16>(name, 5);
    }

    public Result<bool> GetBool(StringView name) mut
    {
        return GetPropertyInternal<bool>(name, 5);
    }

    public Result<Vec3<f32>> GetVec3(StringView name) mut
    {
        return GetPropertyInternal<Vec3<f32>>(name, 5);
    }

    public Result<Mat3> GetMat3(StringView name) mut
    {
        return GetPropertyInternal<Mat3>(name, 5);
    }

    public Result<PositionOrient> GetPositionOrient(StringView name) mut
    {
        return GetPropertyInternal<PositionOrient>(name, 5);
    }

    public Result<BoundingBox> GetBBox(StringView name) mut
    {
        return GetPropertyInternal<BoundingBox>(name, 5);
    }

    public Result<Span<u8>> GetBuffer(StringView name) mut
	{
        readonly u32 nameHash = Hash.HashVolitionCRC(name, 0);
        for (Property* prop in Properties)
        {
            if (prop.NameHash == nameHash)
            {
                if (prop.Type != 6)
                    return .Err;

                return Span<u8>((u8*)prop.Data, prop.Size);
            }
        }

        return .Err;
	}

    public Result<StringView> GetString(StringView name) mut
    {
        readonly u32 nameHash = Hash.HashVolitionCRC(name, 0);
        for (Property* prop in Properties)
        {
            if (prop.NameHash == nameHash)
            {
                if (prop.Type != 4)
                    return .Err;

                return StringView((char8*)prop.Data, prop.Size);
            }
        }

        return .Err;
    }

    [CRepr, RequiredSize(8)]
    public struct Property
    {
        public u16 Type;
        public u16 Size;
        public u32 NameHash;

        public StringView Name => HashDictionary.FindOriginString(NameHash).GetValueOrDefault("UnknownProperty");
        public u8* Data mut => ((u8*)&this) + sizeof(Property); //Data immediately follows property header
    }

    public struct PropertyEnumerator : IEnumerator<Property*>
    {
        Property* _curProperty = null;
        readonly u16 _numProps = 0;
        u16 _curIndex = 0;

        public this(Property* firstProp, u16 numProps)
        {
            _curProperty = firstProp;
            _numProps = numProps;
            _curIndex = 0;
        }

        public Result<Property*> GetNext() mut
        {
            if (_numProps == 0)
                return .Err;
            if (_curIndex == _numProps - 1)
                return .Err;
            if (_curIndex == 0)
            {
                _curIndex++;
                return _curProperty;
            }

            u8* propBytes = (u8*)_curProperty;
            propBytes += sizeof(Property) + _curProperty.Size + (int)System.IO.Stream.CalcAlignment(_curProperty.Size, 4);
            _curProperty = (Property*)propBytes;
            _curIndex++;

            return _curProperty;
        }
    }
}