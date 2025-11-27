// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * P2P Arbitration Anonymous Scoring (Trust Without History)
 *
 * - Any rater submits an encrypted score (0..100) for a target address.
 * - Contract stores per-target only: encrypted sum of scores (euint16) and plain count (uint16).
 * - No per-rater history or identities are stored on-chain.
 * - Owner sets encrypted policy: min average thresholds for Bronze/Silver/Gold.
 * - Verdict functions:
 *      * verdictPrivate(target): returns encrypted tier code (0..3), decryptable by caller only.
 *      * verdictPublic(target):  same, but marked publicly decryptable (global).
 *
 * Average can be computed off-chain from (publicly decryptable) sum and plain count if desired.
 */

import {
    FHE,
    ebool,
    euint8,
    euint16,
    externalEuint16
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract AnonymousArbScoring is ZamaEthereumConfig {
    /* ───────── Meta / Ownership ───────── */

    function version() external pure returns (string memory) {
        return "AnonymousArbScoring/1.0.0";
    }

    address public owner;
    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor() {
        owner = msg.sender;

        // Safe defaults to avoid zero-handles reads before init
        _avgBronzeMin = FHE.asEuint16(0);
        _avgSilverMin = FHE.asEuint16(0);
        _avgGoldMin   = FHE.asEuint16(0);

        FHE.allowThis(_avgBronzeMin);
        FHE.allowThis(_avgSilverMin);
        FHE.allowThis(_avgGoldMin);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero owner");
        owner = newOwner;
    }

    /* ───────── Policy (encrypted thresholds) ─────────
       Each is a 0..100 integer interpreted as "minimum average".
       Example: Bronze >= 50, Silver >= 70, Gold >= 90.
    */

    euint16 private _avgBronzeMin;
    euint16 private _avgSilverMin;
    euint16 private _avgGoldMin;

    event PolicyUpdated(bytes32 bronzeH, bytes32 silverH, bytes32 goldH);

    function setPolicyEncrypted(
        externalEuint16 bronzeMinExt,
        externalEuint16 silverMinExt,
        externalEuint16 goldMinExt,
        bytes calldata proof
    ) external onlyOwner {
        euint16 b = FHE.fromExternal(bronzeMinExt, proof);
        euint16 s = FHE.fromExternal(silverMinExt, proof);
        euint16 g = FHE.fromExternal(goldMinExt, proof);

        _avgBronzeMin = b;
        _avgSilverMin = s;
        _avgGoldMin   = g;

        FHE.allowThis(_avgBronzeMin);
        FHE.allowThis(_avgSilverMin);
        FHE.allowThis(_avgGoldMin);

        emit PolicyUpdated(
            FHE.toBytes32(_avgBronzeMin),
            FHE.toBytes32(_avgSilverMin),
            FHE.toBytes32(_avgGoldMin)
        );
    }

    function makePolicyPublic() external onlyOwner {
        FHE.makePubliclyDecryptable(_avgBronzeMin);
        FHE.makePubliclyDecryptable(_avgSilverMin);
        FHE.makePubliclyDecryptable(_avgGoldMin);
    }

    function getPolicyHandles()
        external
        view
        returns (bytes32 bronzeH, bytes32 silverH, bytes32 goldH)
    {
        return (
            FHE.toBytes32(_avgBronzeMin),
            FHE.toBytes32(_avgSilverMin),
            FHE.toBytes32(_avgGoldMin)
        );
    }

    /* ───────── Aggregates per target ───────── */

    struct Agg {
        bool exists;
        euint16 sum;   // encrypted sum of scores (0..100)
        uint16 count;  // number of submissions
    }

    mapping(address => Agg) private _agg;

    event Scored(address indexed target, uint16 newCount, bytes32 sumHandle);
    event SumPublished(address indexed target, bytes32 sumHandle);
    event VerdictPrivate(address indexed caller, address indexed target, bytes32 verdictHandle);
    event VerdictPublic(address indexed caller, address indexed target, bytes32 verdictHandle);

    /* ───────── Submit score (encrypted) ───────── */

    /**
     * @notice Submit an encrypted score (0..100) for `target`.
     * @dev    `scoreExt` is externalEuint16 (Relayer SDK add16). No rater identity is stored.
     *         Count is plain. Sum is kept as euint16 (max ~65535).
     */
    function submitScore(
        address target,
        externalEuint16 scoreExt,
        bytes calldata proof
    ) external {
        require(target != address(0), "Zero target");

        // Deserialize encrypted score
        euint16 score = FHE.fromExternal(scoreExt, proof);

        Agg storage a = _agg[target];
        if (!a.exists) {
            a.exists = true;
            a.sum = FHE.asEuint16(0); // init
            FHE.allowThis(a.sum);
            a.count = 0;
        }

        // sum' = sum + score
        euint16 newSum = FHE.add(a.sum, score);
        a.sum = newSum;
        FHE.allowThis(a.sum);

        // count' = count + 1  (bounded by uint16)
        require(a.count < type(uint16).max, "Count overflow");
        unchecked { a.count += 1; }

        emit Scored(target, a.count, FHE.toBytes32(a.sum));
    }

    /* ───────── Aggregate reads / publication ───────── */

    /// @notice Return handle of encrypted sum and plain count (for off-chain average).
    function getAggregateHandles(address target)
        external
        view
        returns (bytes32 sumHandle, uint16 count)
    {
        Agg storage a = _agg[target];
        if (!a.exists) return (bytes32(0), 0);
        return (FHE.toBytes32(a.sum), a.count);
    }

    /// @notice Make the encrypted sum publicly decryptable (optional).
    function publishSum(address target) external returns (bytes32 handle) {
        Agg storage a = _agg[target];
        require(a.exists, "No agg");
        FHE.makePubliclyDecryptable(a.sum);
        handle = FHE.toBytes32(a.sum);
        emit SumPublished(target, handle);
    }

    /* ───────── Verdict (tier code: 0..3) ─────────
       0 = None, 1 = Bronze, 2 = Silver, 3 = Gold.
       Comparison trick (no division): avg >= X  <=>  sum >= X * count
    */

    function _tierCode(address target) internal returns (euint8 code) {
        Agg storage a = _agg[target];
        require(a.exists && a.count > 0, "No data");

        // Prepare ciphertexts
        euint16 countCt = FHE.asEuint16(a.count); // safe: count is plain
        euint16 bronzeProd = FHE.mul(_avgBronzeMin, countCt);
        euint16 silverProd = FHE.mul(_avgSilverMin, countCt);
        euint16 goldProd   = FHE.mul(_avgGoldMin,   countCt);

        // Checks: sum >= threshold * count
        ebool bronzeOk = FHE.ge(a.sum, bronzeProd);
        ebool silverOk = FHE.ge(a.sum, silverProd);
        ebool goldOk   = FHE.ge(a.sum, goldProd);

        // Build tier code (0..3). Prefer the highest satisfied.
        // code = 3 if goldOk else 2 if silverOk else 1 if bronzeOk else 0
        euint8 codeGold   = FHE.asEuint8(3);
        euint8 codeSilver = FHE.asEuint8(2);
        euint8 codeBronze = FHE.asEuint8(1);
        euint8 codeNone   = FHE.asEuint8(0);

        euint8 s1 = FHE.select(goldOk,   codeGold,   codeSilver); // gold ? 3 : 2
        euint8 s2 = FHE.select(silverOk, s1,         codeBronze); // silver? s1 : 1
        euint8 s3 = FHE.select(bronzeOk, s2,         codeNone);   // bronze? s2 : 0

        // Allow contract to reuse intermediates
        FHE.allowThis(countCt);
        FHE.allowThis(bronzeProd);
        FHE.allowThis(silverProd);
        FHE.allowThis(goldProd);
        FHE.allowThis(s1);
        FHE.allowThis(s2);
        FHE.allowThis(s3);

        return s3;
    }

    /**
     * @notice Encrypted verdict (tier code 0..3) — caller-only decryption.
     */
    function verdictPrivate(address target) external returns (euint8 outCode) {
        euint8 code = _tierCode(target);
        FHE.allow(code, msg.sender); // private to caller
        FHE.allowThis(code);
        emit VerdictPrivate(msg.sender, target, FHE.toBytes32(code));
        return code;
    }

    /**
     * @notice Encrypted verdict (tier code 0..3) — publicly decryptable.
     */
    function verdictPublic(address target) external returns (euint8 outCode) {
        euint8 code = _tierCode(target);
        FHE.makePubliclyDecryptable(code);
        FHE.allowThis(code);
        emit VerdictPublic(msg.sender, target, FHE.toBytes32(code));
        return code;
    }

    /* ───────── Optional maintenance ───────── */

    /// @notice Reset aggregate for a target (owner-only). Note: euint can't be deleted; re-init instead.
    function resetTarget(address target) external onlyOwner {
        Agg storage a = _agg[target];
        a.exists = false;
        a.sum = FHE.asEuint16(0);
        FHE.allowThis(a.sum);
        a.count = 0;
    }
}
