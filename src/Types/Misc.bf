using Common.Math;
using Common;
using System;
using Common.Misc;

namespace RfgTools.Types
{
    [CRepr, RequiredSize(48)]
    struct PositionOrient
    {
        public Vec3 Position;
        public Mat3 Orient;
    }

    static class RfgTypeChecker
    {
        [OnCompile(.TypeInit)]
        private static void TypeSizeChecks()
        {
            Runtime.Assert(sizeof(PositionOrient) == 48, "sizeof(PositionOrient) must be 48 bytes to match RFG zone file format.");
        }
    }
}