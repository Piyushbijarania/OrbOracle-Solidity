// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "lib/forge-std/src/Test.sol";
import {ComposedOracle, ComposedOracleByMultiplication, ComposedOracleByDivision} from "../src/ComposedOracle.sol";
import {ComposedOracleFactory} from "../src/ComposedOracleFactory.sol";

contract MockFuzzOracle {
    uint256 private price;
    uint256 private lastSubTime;
    uint256[] public history;
    uint256[] public historyTimestamps;
    string public description = "Mock Fuzz Feed";

    mapping(address => bool) private blacklisted;

    constructor(uint256 _price) {
        price = _price;
        lastSubTime = block.timestamp;
    }

    function pushHistory(uint256 timestamp, uint256 value) external {
        historyTimestamps.push(timestamp);
        history.push(value);
    }

    function clearHistory() external {
        delete history;
        delete historyTimestamps;
    }

    function getHistoryLength() external view returns (uint256) {
        return history.length;
    }

    function readValue() external view returns (uint256) {
        return price;
    }

    function readLatestValue() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function lastUpdated() external view returns (uint256) {
        return lastSubTime;
    }

    function setLastUpdated(uint256 _time) external {
        lastSubTime = _time;
    }

    function isBlacklisted(address target) external view returns (bool) {
        return blacklisted[target];
    }

    function setBlacklisted(address target, bool _status) external {
        blacklisted[target] = _status;
    }
}

contract ComposedOracleFuzzTest is Test {
    MockFuzzOracle internal feedA;
    MockFuzzOracle internal feedB;
    MockFuzzOracle internal feedC;

    uint256 private constant WAD = 1e18;

    function setUp() public {
        feedA = new MockFuzzOracle(0);
        feedB = new MockFuzzOracle(0);
        feedC = new MockFuzzOracle(0);
    }

    // Test multiplication scaling, commutativity, and boundaries
    function testFuzz_MultiplicationMath(uint256 priceA, uint256 priceB) public {
        priceA = bound(priceA, 0, 1e38);
        priceB = bound(priceB, 0, 1e38);

        feedA.setPrice(priceA);
        feedB.setPrice(priceB);

        ComposedOracle composedAB = new ComposedOracleByMultiplication(
            address(feedA), address(feedB), false, 100, "A * B"
        );
        ComposedOracle composedBA = new ComposedOracleByMultiplication(
            address(feedB), address(feedA), false, 100, "B * A"
        );

        uint256 expected = (priceA * priceB) / WAD;
        uint256 valAB = composedAB.readValue();
        uint256 valBA = composedBA.readValue();

        assertEq(valAB, expected);
        assertEq(valAB, valBA);
        assertEq(composedAB.readLatestValue(), expected);

        if (priceB == WAD) {
            assertEq(valAB, priceA);
        }
        if (priceA == 0 || priceB == 0) {
            assertEq(valAB, 0);
        }
        if (priceA > 0 && priceB > 0 && (priceA * priceB) < WAD) {
            assertEq(valAB, 0);
        }
    }

    // Test division math, identity, and fractional prices
    function testFuzz_DivisionMath(uint256 priceA, uint256 priceB) public {
        priceA = bound(priceA, 0, 1e58);
        priceB = bound(priceB, 1, 1e58);

        feedA.setPrice(priceA);
        feedB.setPrice(priceB);

        ComposedOracle composed = new ComposedOracleByDivision(
            address(feedA), address(feedB), false, 100, "A / B"
        );

        uint256 expected = (priceA * WAD) / priceB;
        uint256 actual = composed.readValue();

        assertEq(actual, expected);
        assertEq(composed.readLatestValue(), expected);

        if (priceA > 0 && priceA < priceB) {
            assertTrue(actual < WAD);
        }
        if (priceA == 0) {
            assertEq(actual, 0);
        }
        if (priceB == WAD) {
            assertEq(actual, priceA);
        }
    }

    // Test division by zero revert
    function testFuzz_DivisionByZeroRevert(uint256 priceA) public {
        priceA = bound(priceA, 0, 1e58);

        feedA.setPrice(priceA);
        feedB.setPrice(0);

        ComposedOracle composed = new ComposedOracleByDivision(
            address(feedA), address(feedB), false, 100, "A / 0"
        );

        vm.expectRevert(ComposedOracle.DivisionByZero.selector);
        composed.readValue();

        vm.expectRevert(ComposedOracle.DivisionByZero.selector);
        composed.readLatestValue();
    }

    // Test inversion math and identity element
    function testFuzz_InversionMath(uint256 priceA, uint256 priceB) public {
        priceA = bound(priceA, 1e15, 1e25);
        priceB = bound(priceB, 1e15, 1e25);

        feedA.setPrice(priceA);
        feedB.setPrice(priceB);

        ComposedOracle composed = new ComposedOracleByMultiplication(
            address(feedA), address(feedB), true, 100, "Inverted (A * B)"
        );

        uint256 rawMul = (priceA * priceB) / WAD;
        vm.assume(rawMul > 0);

        uint256 expected = (WAD * WAD) / rawMul;
        uint256 actual = composed.readValue();
        assertEq(actual, expected);

        feedA.setPrice(WAD);
        feedB.setPrice(WAD);
        assertEq(composed.readValue(), WAD);
    }

    // Test inversion reverts if product rounds down to zero
    function testFuzz_InversionZeroRevert(uint256 priceA, uint256 priceB) public {
        priceA = bound(priceA, 0, 1e8);
        priceB = bound(priceB, 0, 1e8);

        vm.assume((priceA * priceB) / WAD == 0);

        feedA.setPrice(priceA);
        feedB.setPrice(priceB);

        ComposedOracle composed = new ComposedOracleByMultiplication(
            address(feedA), address(feedB), true, 100, "Inverted Zero"
        );

        vm.expectRevert(ComposedOracle.DivisionByZero.selector);
        composed.readValue();
    }

    // Independent point-in-time reference model for lookback intervals
    function _computeExpectedInterval(
        uint256[] memory timesA,
        uint256[] memory valsA,
        uint256[] memory timesB,
        uint256[] memory valsB,
        uint256 sampleSize,
        bool isDivision
    ) internal pure returns (uint256 expMin, uint256 expMax) {
        uint256 lenA = timesA.length;
        uint256 lenB = timesB.length;
        require(lenA > 0 && lenB > 0, "Empty history");

        // Merge all timestamps
        uint256 total = lenA + lenB;
        uint256[] memory allTimes = new uint256[](total);
        uint256 count = 0;
        for (uint256 i = 0; i < lenA; i++) {
            allTimes[count++] = timesA[i];
        }
        for (uint256 j = 0; j < lenB; j++) {
            allTimes[count++] = timesB[j];
        }

        // Sort timestamps descending
        for (uint256 i = 0; i < total; i++) {
            for (uint256 j = i + 1; j < total; j++) {
                if (allTimes[j] > allTimes[i]) {
                    uint256 tmp = allTimes[i];
                    allTimes[i] = allTimes[j];
                    allTimes[j] = tmp;
                }
            }
        }

        // Deduplicate timestamps
        uint256[] memory uniqueTimes = new uint256[](total);
        uint256 uCount = 0;
        for (uint256 i = 0; i < total; i++) {
            if (uCount == 0 || allTimes[i] != uniqueTimes[uCount - 1]) {
                uniqueTimes[uCount++] = allTimes[i];
            }
        }

        expMin = type(uint256).max;
        expMax = 0;
        uint256 samplesTaken = 0;

        for (uint256 k = 0; k < uCount && samplesTaken < sampleSize; k++) {
            uint256 T = uniqueTimes[k];

            bool foundA = false;
            uint256 vA = 0;
            for (int256 a = int256(lenA) - 1; a >= 0; a--) {
                if (timesA[uint256(a)] <= T) {
                    vA = valsA[uint256(a)];
                    foundA = true;
                    break;
                }
            }

            bool foundB = false;
            uint256 vB = 0;
            for (int256 b = int256(lenB) - 1; b >= 0; b--) {
                if (timesB[uint256(b)] <= T) {
                    vB = valsB[uint256(b)];
                    foundB = true;
                    break;
                }
            }

            if (!foundA || !foundB) {
                break;
            }

            uint256 compVal = !isDivision ? (vA * vB) / WAD : (vA * WAD) / vB;
            if (compVal < expMin) expMin = compVal;
            if (compVal > expMax) expMax = compVal;
            samplesTaken++;
        }
    }

    // Test multiplication lookback interval against independent reference model
    function testFuzz_ReadValueInterval_Multiplication_ExactReference(
        uint8 historyLenA,
        uint8 historyLenB,
        uint8 sampleSize,
        uint256[6] memory pricesA,
        uint256[6] memory pricesB,
        uint8 timeStepSeed
    ) public {
        uint256 lenA = bound(historyLenA, 1, 6);
        uint256 lenB = bound(historyLenB, 1, 6);
        uint256 samples = bound(sampleSize, 1, 15);

        feedA.clearHistory();
        feedB.clearHistory();

        uint256[] memory timesA = new uint256[](lenA);
        uint256[] memory valsA = new uint256[](lenA);
        uint256[] memory timesB = new uint256[](lenB);
        uint256[] memory valsB = new uint256[](lenB);

        uint256 currentA = 1000;
        for (uint256 i = 0; i < lenA; i++) {
            currentA += 10 + (uint256(timeStepSeed) % 15);
            uint256 p = bound(pricesA[i], 1e16, 1e25);
            timesA[i] = currentA;
            valsA[i] = p;
            feedA.pushHistory(currentA, p);
        }

        uint256 currentB = 1005;
        for (uint256 j = 0; j < lenB; j++) {
            currentB += 12 + ((uint256(timeStepSeed) + j) % 15);
            uint256 p = bound(pricesB[j], 1e16, 1e25);
            timesB[j] = currentB;
            valsB[j] = p;
            feedB.pushHistory(currentB, p);
        }

        ComposedOracle composed = new ComposedOracleByMultiplication(
            address(feedA), address(feedB), false, samples, "Mul Reference Test"
        );

        (uint256 actualMin, uint256 actualMax) = composed.readValueInterval();
        (uint256 expectedMin, uint256 expectedMax) = _computeExpectedInterval(
            timesA, valsA, timesB, valsB, samples, false
        );

        assertEq(actualMin, expectedMin);
        assertEq(actualMax, expectedMax);
        assertLe(actualMin, actualMax);
    }

    // Test division lookback interval against independent reference model
    function testFuzz_ReadValueInterval_Division_ExactReference(
        uint8 historyLenA,
        uint8 historyLenB,
        uint8 sampleSize,
        uint256[6] memory pricesA,
        uint256[6] memory pricesB,
        uint8 timeStepSeed
    ) public {
        uint256 lenA = bound(historyLenA, 1, 6);
        uint256 lenB = bound(historyLenB, 1, 6);
        uint256 samples = bound(sampleSize, 1, 15);

        feedA.clearHistory();
        feedB.clearHistory();

        uint256[] memory timesA = new uint256[](lenA);
        uint256[] memory valsA = new uint256[](lenA);
        uint256[] memory timesB = new uint256[](lenB);
        uint256[] memory valsB = new uint256[](lenB);

        uint256 currentA = 2000;
        for (uint256 i = 0; i < lenA; i++) {
            currentA += 10 + (uint256(timeStepSeed) % 10);
            uint256 p = bound(pricesA[i], 1e16, 1e25);
            timesA[i] = currentA;
            valsA[i] = p;
            feedA.pushHistory(currentA, p);
        }

        uint256 currentB = 2002;
        for (uint256 j = 0; j < lenB; j++) {
            currentB += 15 + ((uint256(timeStepSeed) + j) % 10);
            uint256 p = bound(pricesB[j], 1e16, 1e25);
            timesB[j] = currentB;
            valsB[j] = p;
            feedB.pushHistory(currentB, p);
        }

        ComposedOracle composed = new ComposedOracleByDivision(
            address(feedA), address(feedB), false, samples, "Div Reference Test"
        );

        (uint256 actualMin, uint256 actualMax) = composed.readValueInterval();
        (uint256 expectedMin, uint256 expectedMax) = _computeExpectedInterval(
            timesA, valsA, timesB, valsB, samples, true
        );

        assertEq(actualMin, expectedMin);
        assertEq(actualMax, expectedMax);
        assertLe(actualMin, actualMax);
    }

    // Test single sample lookback matches latest price
    function testFuzz_ReadValueInterval_SingleSampleEqualsLatest(
        uint256 priceA,
        uint256 priceB
    ) public {
        priceA = bound(priceA, 1e16, 1e26);
        priceB = bound(priceB, 1e16, 1e26);

        feedA.clearHistory();
        feedB.clearHistory();

        feedA.pushHistory(100, priceA);
        feedB.pushHistory(100, priceB);

        ComposedOracle composed = new ComposedOracleByMultiplication(
            address(feedA), address(feedB), false, 1, "Single Sample"
        );

        (uint256 minValue, uint256 maxValue) = composed.readValueInterval();
        uint256 expectedLatest = (priceA * priceB) / WAD;

        assertEq(minValue, maxValue);
        assertEq(minValue, expectedLatest);
    }

    // Test blacklist propagation in a 3-tier composed tree
    function testFuzz_DeepNestedBlacklistPropagation(
        address caller,
        bool blacklistA,
        bool blacklistB,
        bool blacklistC
    ) public {
        vm.assume(caller != address(0));

        feedA.setPrice(10 * WAD);
        feedB.setPrice(2 * WAD);
        feedC.setPrice(5 * WAD);

        feedA.pushHistory(100, 10 * WAD);
        feedB.pushHistory(100, 2 * WAD);
        feedC.pushHistory(100, 5 * WAD);

        feedA.setBlacklisted(caller, blacklistA);
        feedB.setBlacklisted(caller, blacklistB);
        feedC.setBlacklisted(caller, blacklistC);

        ComposedOracle childComposed = new ComposedOracleByMultiplication(
            address(feedA), address(feedB), false, 1, "Child A * B"
        );
        ComposedOracle rootComposed = new ComposedOracleByDivision(
            address(childComposed), address(feedC), false, 1, "Root (A * B) / C"
        );

        bool anyBlacklisted = blacklistA || blacklistB || blacklistC;
        assertEq(rootComposed.isBlacklisted(caller), anyBlacklisted);

        vm.prank(caller);
        if (anyBlacklisted) {
            vm.expectRevert(ComposedOracle.BlacklistedCaller.selector);
            rootComposed.readValue();

            vm.prank(caller);
            vm.expectRevert(ComposedOracle.BlacklistedCaller.selector);
            rootComposed.readLatestValue();

            vm.prank(caller);
            vm.expectRevert(ComposedOracle.BlacklistedCaller.selector);
            rootComposed.readValueInterval();
        } else {
            assertEq(rootComposed.readValue(), 4 * WAD);
            assertEq(rootComposed.readLatestValue(), 4 * WAD);
        }
    }

    // Test lastUpdated returns minimum timestamp of parent feeds
    function testFuzz_LastUpdatedMinimum(uint256 timeA, uint256 timeB) public {
        feedA.setLastUpdated(timeA);
        feedB.setLastUpdated(timeB);

        ComposedOracle composed = new ComposedOracleByMultiplication(
            address(feedA), address(feedB), false, 100, "Timestamp Test"
        );

        uint256 expected = timeA < timeB ? timeA : timeB;
        assertEq(composed.lastUpdated(), expected);
    }

    // Test multi-level nested composition created through factory
    function testFuzz_NestedFactoryTreeComposition(
        uint256 priceA,
        uint256 priceB,
        uint256 priceD
    ) public {
        priceA = bound(priceA, 1e16, 1e24);
        priceB = bound(priceB, 1e16, 1e24);
        priceD = bound(priceD, 1e16, 1e24);

        feedA.setPrice(priceA);
        feedB.setPrice(priceB);
        feedC.setPrice(priceD);

        feedA.setLastUpdated(100);
        feedB.setLastUpdated(200);
        feedC.setLastUpdated(150);

        ComposedOracleFactory factory = new ComposedOracleFactory(address(this));

        address oracleC = factory.createComposedOracle(
            address(feedA), address(feedB), 0, false, 10, "C = A * B"
        );
        address oracleF = factory.createComposedOracle(
            oracleC, address(feedC), 1, false, 10, "F = C / D"
        );
        address oracleRoot = factory.createComposedOracle(
            oracleC, oracleF, 0, false, 10, "Root = C * F"
        );

        assertEq(factory.allComposedOracles().length, 3);
        assertEq(factory.creatorComposedOracleList(address(this)).length, 3);

        uint256 expectedC = (priceA * priceB) / WAD;
        uint256 expectedF = (expectedC * WAD) / priceD;
        uint256 expectedRoot = (expectedC * expectedF) / WAD;

        ComposedOracle root = ComposedOracle(oracleRoot);
        assertEq(root.readValue(), expectedRoot);
        assertEq(root.readLatestValue(), expectedRoot);
        assertEq(root.lastUpdated(), 100);

        feedB.setBlacklisted(address(0xbeef), true);
        assertTrue(root.isBlacklisted(address(0xbeef)));

        vm.prank(address(0xbeef));
        vm.expectRevert(ComposedOracle.BlacklistedCaller.selector);
        root.readValue();
    }

    // Test deep chain nesting up to 12 levels deep
    function testFuzz_DeepChainNesting(uint8 depthSeed) public {
        uint256 depth = bound(depthSeed, 2, 12);

        MockFuzzOracle baseFeed = new MockFuzzOracle(2 * WAD);
        baseFeed.setLastUpdated(500);

        MockFuzzOracle identityFeed = new MockFuzzOracle(WAD);
        identityFeed.setLastUpdated(1000);

        address currentOracle = address(baseFeed);

        for (uint256 i = 0; i < depth; i++) {
            currentOracle = address(
                new ComposedOracleByMultiplication(
                    currentOracle,
                    address(identityFeed),
                    false,
                    10,
                    "Chain Node"
                )
            );
        }

        ComposedOracle root = ComposedOracle(currentOracle);

        assertEq(root.readValue(), 2 * WAD);
        assertEq(root.readLatestValue(), 2 * WAD);
        assertEq(root.lastUpdated(), 500);

        baseFeed.setBlacklisted(address(0xdead), true);
        assertTrue(root.isBlacklisted(address(0xdead)));

        vm.prank(address(0xdead));
        vm.expectRevert(ComposedOracle.BlacklistedCaller.selector);
        root.readValue();
    }

    // Test nested interval reverts when parent lacks history storage
    function test_NestedIntervalRevertsGracefullyWithoutHistory() public {
        feedA.setPrice(10 * WAD);
        feedB.setPrice(2 * WAD);
        feedC.setPrice(5 * WAD);

        feedA.pushHistory(100, 10 * WAD);
        feedB.pushHistory(100, 2 * WAD);
        feedC.pushHistory(100, 5 * WAD);

        ComposedOracle childComposed = new ComposedOracleByMultiplication(
            address(feedA), address(feedB), false, 10, "Child"
        );
        ComposedOracle rootComposed = new ComposedOracleByDivision(
            address(childComposed), address(feedC), false, 10, "Root"
        );

        assertEq(rootComposed.readValue(), 4 * WAD);
        assertEq(rootComposed.readLatestValue(), 4 * WAD);

        vm.expectRevert();
        rootComposed.readValueInterval();
    }
}
