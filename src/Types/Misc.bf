using Common.Math;
using Common;
using System;

namespace RfgTools.Types
{
    [CRepr]
    struct PositionOrient
    {
        public Vec3<f32> Position;
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