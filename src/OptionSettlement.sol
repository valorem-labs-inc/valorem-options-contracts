// SPDX-License-Identifier: BUSL 1.1
pragma solidity 0.8.11;

import "base64/Base64.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/tokens/ERC1155.sol";
import "./interfaces/IOptionSettlementEngine.sol";
import "solmate/utils/SafeTransferLib.sol";
import "solmate/utils/FixedPointMathLib.sol";
import "./TokenURIGenerator.sol";

/**
 * Valorem Options V1 is a DeFi money lego enabling writing covered call and covered put, physically settled, options.
 * All written options are fully collateralized against an ERC-20 underlying asset and exercised with an
 * ERC-20 exercise asset using a pseudorandom number per unique option type for fair settlement. Options contracts
 * are issued as fungible ERC-1155 tokens, with each token representing a contract. Option writers are additionally issued
 * an ERC-1155 NFT representing a lot of contracts written for claiming collateral and exercise assignment. This design
 * eliminates the need for market price oracles, and allows for permission-less writing, and gas efficient transfer, of
 * a broad swath of traditional options.
 */

// TODO(DRY code during testing)
// TODO(Gas Optimize)

/// @notice This settlement protocol does not support rebase tokens, or fee on transfer tokens
contract OptionSettlementEngine is ERC1155, IOptionSettlementEngine {
    /// @notice The protocol fee
    uint8 public immutable feeBps = 5;

    /// @notice The address fees accrue to
    address public feeTo = 0x36273803306a3C22bc848f8Db761e974697ece0d;

    /// @notice Fee balance for a given token
    mapping(address => uint256) public feeBalance;

    /// @notice Accessor for Option contract details
    mapping(uint160 => Option) internal _option;

    /// @notice Accessor for claim ticket details
    mapping(uint256 => Claim) internal _claim;

    /// @notice Accessor for buckets of claims grouped by day
    /// @dev This is to enable O(constant) time options exercise. When options are written,
    /// the Claim struct in this mapping is updated to reflect the cumulative amount written
    /// on the day in question (block.timestamp/# seconds in a day). This allows
    /// exercise() to assign options on each bucket from 'today' up until option expiry,
    /// rather than a costly iteration of every unexercised claim on an option.
    mapping(uint160 => mapping(uint16 => ClaimBucket)) internal _claimBucketByOptionAndDay;

    /// @notice Accessor for mapping a claim id to its bucketed day
    mapping(uint256 => uint16) internal _claimIdToBucket;

    uint256 public hashMask = 0xFFFFFFFFFFFFFFFFFFFF000000000000;

    /// @inheritdoc IOptionSettlementEngine
    function option(uint256 tokenId) external view returns (Option memory optionInfo) {
        // TODO: Revert if claim IDX is specified?
        (uint160 optionId,) = getDecodedIdComponents(tokenId);
        optionInfo = _option[optionId];
    }

    /// @inheritdoc IOptionSettlementEngine
    function claim(uint256 tokenId) external view returns (Claim memory claimInfo) {
        claimInfo = _claim[tokenId];
    }

    /// @inheritdoc IOptionSettlementEngine
    function tokenType(uint256 tokenId) external pure returns (Type) {
        (, uint96 claimIdx) = getDecodedIdComponents(tokenId);
        // TODO: should we do a read here and ensure the token exists?
        if (claimIdx == 0) {
            return Type.Option;
        }
        return Type.Claim;
    }

    /// @inheritdoc IOptionSettlementEngine
    function setFeeTo(address newFeeTo) public {
        if (msg.sender != feeTo) {
            revert AccessControlViolation(msg.sender, feeTo);
        }
        feeTo = newFeeTo;
    }

    /// @inheritdoc IOptionSettlementEngine
    function sweepFees(address[] memory tokens) public {
        address sendFeeTo = feeTo;
        address token;
        uint256 fee;
        uint256 sweep;
        uint256 numTokens = tokens.length;

        unchecked {
            for (uint256 i = 0; i < numTokens; i++) {
                // Get the token and balance to sweep
                token = tokens[i];

                fee = feeBalance[token];
                // Leave 1 wei here as a gas optimization
                if (fee > 1) {
                    sweep = feeBalance[token] - 1;
                    SafeTransferLib.safeTransfer(ERC20(token), sendFeeTo, sweep);
                    feeBalance[token] = 1;
                    emit FeeSwept(token, sendFeeTo, sweep);
                }
            }
        }
    }

    function uri(uint256 tokenId) public view virtual override returns (string memory) {
        Option memory optionInfo;
        (uint160 optionId, uint96 claimId) = getDecodedIdComponents(tokenId);
        optionInfo = _option[optionId];

        if (optionInfo.underlyingAsset == address(0x0)) {
            revert TokenNotFound(tokenId);
        }

        Type _type = claimId == 0 ? Type.Option : Type.Claim;

        TokenURIGenerator.TokenURIParams memory params = TokenURIGenerator.TokenURIParams({
            underlyingAsset: optionInfo.underlyingAsset,
            underlyingSymbol: ERC20(optionInfo.underlyingAsset).symbol(),
            exerciseAsset: optionInfo.exerciseAsset,
            exerciseSymbol: ERC20(optionInfo.exerciseAsset).symbol(),
            exerciseTimestamp: optionInfo.exerciseTimestamp,
            expiryTimestamp: optionInfo.expiryTimestamp,
            underlyingAmount: optionInfo.underlyingAmount,
            exerciseAmount: optionInfo.exerciseAmount,
            tokenType: _type
        });

        return TokenURIGenerator.constructTokenURI(params);
    }

    /// @inheritdoc IOptionSettlementEngine
    function newOptionType(Option memory optionInfo) external returns (uint256 optionId) {
        // Check that a duplicate option type doesn't exist
        bytes20 optionHash = bytes20(keccak256(abi.encode(optionInfo)));
        uint160 optionKey = uint160(optionHash);
        optionId = uint256(optionKey) << 96;

        // If it does, revert
        if (isOptionInitialized(optionKey)) {
            revert OptionsTypeExists(optionId);
        }

        // Make sure that expiry is at least 24 hours from now
        if (optionInfo.expiryTimestamp < (block.timestamp + 86400)) {
            revert ExpiryTooSoon(optionId, optionInfo.expiryTimestamp);
        }

        // Ensure the exercise window is at least 24 hours
        if (optionInfo.expiryTimestamp < (optionInfo.exerciseTimestamp + 86400)) {
            revert ExerciseWindowTooShort();
        }

        // The exercise and underlying assets can't be the same
        if (optionInfo.exerciseAsset == optionInfo.underlyingAsset) {
            revert InvalidAssets(optionInfo.exerciseAsset, optionInfo.underlyingAsset);
        }

        optionInfo.nextClaimId = 1;
        optionInfo.creationTimestamp = uint40(block.timestamp);

        // TODO(Is this check really needed?)
        // Check that both tokens are ERC20 by instantiating them and checking supply
        ERC20 underlyingToken = ERC20(optionInfo.underlyingAsset);
        ERC20 exerciseToken = ERC20(optionInfo.exerciseAsset);

        // Check total supplies and ensure the option will be exercisable
        if (
            underlyingToken.totalSupply() < optionInfo.underlyingAmount
                || exerciseToken.totalSupply() < optionInfo.exerciseAmount
        ) {
            revert InvalidAssets(optionInfo.underlyingAsset, optionInfo.exerciseAsset);
        }

        _option[optionKey] = optionInfo;

        emit NewOptionType(
            optionId,
            optionInfo.exerciseAsset,
            optionInfo.underlyingAsset,
            optionInfo.exerciseAmount,
            optionInfo.underlyingAmount,
            optionInfo.exerciseTimestamp,
            optionInfo.expiryTimestamp,
            optionInfo.nextClaimId,
            optionInfo.creationTimestamp
            );
    }

    /// @inheritdoc IOptionSettlementEngine
    function write(uint256 optionId, uint112 amount) external returns (uint256 claimId) {
        /// supplying claimId as 0 to the overloaded write signifies that a new
        /// claim NFT should be minted for the options lot, rather than being added
        /// as an existing claim.
        return write(optionId, amount, 0);
    }

    /// @inheritdoc IOptionSettlementEngine
    function write(uint256 optionId, uint112 amount, uint256 claimId) public returns (uint256) {
        (uint160 _optionIdU160b, uint96 _optionIdL96b) = getDecodedIdComponents(optionId);

        // optionId must be zero in lower 96b for provided option Id
        if (_optionIdL96b != 0) {
            revert InvalidOption(optionId);
        }

        // claim provided must match the option provided
        if (claimId != 0 && ((claimId >> 96) != (optionId >> 96))) {
            revert EncodedOptionIdInClaimIdDoesNotMatchProvidedOptionId(claimId, optionId);
        }

        Option storage optionRecord = _writeOptions(_optionIdU160b, amount);
        uint256 mintClaimNft = 0;
        uint16 daysAfterOptionCreation = _getDaysAfterOptionCreation(optionRecord);

        if (claimId == 0) {
            // create new claim
            // Increment the next token ID
            uint96 claimIndex = optionRecord.nextClaimId++;
            claimId = getTokenId(_optionIdU160b, claimIndex);
            // Store info about the claim
            _claim[claimId] = Claim({amountWritten: amount, claimBucketId: daysAfterOptionCreation, claimed: false});
            mintClaimNft = 1;
        } else {
            // check ownership of claim
            uint256 balance = balanceOf[msg.sender][claimId];
            if (balance != 1) {
                revert CallerDoesNotOwnClaimId(claimId);
            }

            // retrieve claim
            Claim storage existingClaim = _claim[claimId];

            if (existingClaim.claimed) {
                revert AlreadyClaimed(claimId);
            }

            existingClaim.amountWritten += amount;
        }

        // Update claim bucket for today
        ClaimBucket storage claimBucket = _claimBucketByOptionAndDay[_optionIdU160b][daysAfterOptionCreation];
        claimBucket.amountWritten += amount;
        _claimIdToBucket[claimId] = daysAfterOptionCreation;

        // Mint the options contracts and claim token
        uint256[] memory tokens = new uint256[](2);
        tokens[0] = optionId;
        tokens[1] = claimId;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = mintClaimNft;

        bytes memory data = new bytes(0);

        // Send tokens to writer
        _batchMint(msg.sender, tokens, amounts, data);

        emit OptionsWritten(optionId, msg.sender, claimId, amount);

        return claimId;
    }

    /**
     * claim buckets are a of set options written on a given day, along with how
     * many of those options that have been exercised. writing options
     * on a given day adds to the amount written in that day's claim bucket.
     * the exercise process
     * exercise is performed by iterating from the claim bucket
     */
    /// @inheritdoc IOptionSettlementEngine
    function exercise(uint256 optionId, uint112 amount) external {
        (uint160 _optionIdU160b, uint96 _optionIdL96b) = getDecodedIdComponents(optionId);

        // option ID should be specified without claim in lower 96b
        if (_optionIdL96b != 0) {
            revert InvalidOption(optionId);
        }

        Option storage optionRecord = _option[_optionIdU160b];

        if (optionRecord.expiryTimestamp <= block.timestamp) {
            revert ExpiredOption(optionId, optionRecord.expiryTimestamp);
        }
        // Require that we have reached the exercise timestamp
        if (optionRecord.exerciseTimestamp >= block.timestamp) {
            revert ExerciseTooEarly(optionId, optionRecord.exerciseTimestamp);
        }

        uint256 rxAmount = optionRecord.exerciseAmount * amount;
        uint256 txAmount = optionRecord.underlyingAmount * amount;
        uint256 fee = ((rxAmount / 10000) * feeBps);
        address exerciseAsset = optionRecord.exerciseAsset;

        // Transfer in the requisite exercise asset
        SafeTransferLib.safeTransferFrom(ERC20(exerciseAsset), msg.sender, address(this), (rxAmount + fee));

        // Transfer out the underlying
        SafeTransferLib.safeTransfer(ERC20(optionRecord.underlyingAsset), msg.sender, txAmount);

        _assignExercise(_optionIdU160b, amount);

        feeBalance[exerciseAsset] += fee;

        _burn(msg.sender, optionId, amount);

        emit FeeAccrued(exerciseAsset, msg.sender, fee);
        emit OptionsExercised(optionId, msg.sender, amount);
    }

    /// @dev Fair assignment is performed here. After option expiry, any claim holder
    /// seeking to redeem their claim for the underlying asset will be able to retrieve
    /// the same ratio of their underlying asset as have been exercised in the claim's
    /// bucket.
    /// @inheritdoc IOptionSettlementEngine
    function redeem(uint256 claimId) external {
        (uint160 _claimIdU160b, uint96 _claimIdL96b) = getDecodedIdComponents(claimId);

        if (_claimIdL96b == 0) {
            revert InvalidClaim(claimId);
        }

        uint256 balance = this.balanceOf(msg.sender, claimId);

        if (balance != 1) {
            revert CallerDoesNotOwnClaimId(claimId);
        }

        Claim storage claimRecord = _claim[claimId];

        if (claimRecord.claimed) {
            revert AlreadyClaimed(claimId);
        }

        Option storage optionRecord = _option[_claimIdU160b];

        if (optionRecord.expiryTimestamp > block.timestamp) {
            revert ClaimTooSoon(claimId, optionRecord.expiryTimestamp);
        }

        uint16 bucketedDayForClaim = _claimIdToBucket[claimId];
        ClaimBucket storage claimBucket = _claimBucketByOptionAndDay[_claimIdU160b][bucketedDayForClaim];

        (uint256 amountExercised, uint256 amountUnexercised) = _getAmountExercised(claimRecord, claimBucket);
        uint256 exerciseAmount = optionRecord.exerciseAmount * amountExercised;
        uint256 underlyingAmount = optionRecord.underlyingAmount * amountUnexercised;

        if (exerciseAmount > 0) {
            SafeTransferLib.safeTransfer(ERC20(optionRecord.exerciseAsset), msg.sender, exerciseAmount);
        }

        if (underlyingAmount > 0) {
            SafeTransferLib.safeTransfer(ERC20(optionRecord.underlyingAsset), msg.sender, underlyingAmount);
        }

        claimRecord.claimed = true;

        _burn(msg.sender, claimId, 1);

        // TODO: stdize emissions vis a vis claim index, option id, token id
        emit ClaimRedeemed(
            claimId,
            _claimIdU160b,
            msg.sender,
            optionRecord.exerciseAsset,
            optionRecord.underlyingAsset,
            uint96(exerciseAmount),
            uint96(underlyingAmount)
            );
    }

    /// @inheritdoc IOptionSettlementEngine
    function underlying(uint256 tokenId) external view returns (Underlying memory underlyingPositions) {
        (uint160 _tokenIdU160b, uint96 _tokenIdL96b) = getDecodedIdComponents(tokenId);

        if (!isOptionInitialized(_tokenIdU160b)) {
            revert TokenNotFound(tokenId);
        }

        // token ID is an option
        if (_tokenIdL96b == 0) {
            Option storage optionRecord = _option[_tokenIdU160b];
            bool expired = (optionRecord.expiryTimestamp > block.timestamp);
            underlyingPositions = Underlying({
                underlyingAsset: optionRecord.underlyingAsset,
                underlyingPosition: expired ? int256(0) : int256(uint256(optionRecord.underlyingAmount)),
                exerciseAsset: optionRecord.exerciseAsset,
                exercisePosition: expired ? int256(0) : -int256(uint256(optionRecord.exerciseAmount))
            });
        } else {
            // token ID is a claim
            Claim storage claimRecord = _claim[tokenId];
            Option storage optionRecord = _option[_tokenIdU160b];
            ClaimBucket storage claimBucket = _claimBucketByOptionAndDay[_tokenIdU160b][claimRecord.claimBucketId];

            (uint256 amountExerciseAsset, uint amountUnderlyingAsset) = 
                _getExerciseAndUnderlyingAssetPositions(optionRecord, claimRecord, claimBucket);

            underlyingPositions = Underlying({
                underlyingAsset: optionRecord.underlyingAsset,
                underlyingPosition: int256(amountUnderlyingAsset),
                exerciseAsset: optionRecord.exerciseAsset,
                exercisePosition: int256(amountExerciseAsset)
            });
        }
    }

    // **********************************************************************
    //                        INTERNAL HELPERS
    // **********************************************************************
    /**
     * @dev Writes the specified number of options, transferring in the requisite
     * underlying assets, and trasnsferring fungible ERC1155 tokens to caller.
     * Reverts if insufficient underlying assets are not available from caller.
     * @param _optionId The options to write.
     * @param amount The amount of options to write.
     */
    function _writeOptions(uint160 _optionId, uint112 amount) internal returns (Option storage) {
        if (amount == 0) {
            revert AmountWrittenCannotBeZero();
        }

        Option storage optionRecord = _option[_optionId];

        if (optionRecord.expiryTimestamp <= block.timestamp) {
            revert ExpiredOption(uint256(_optionId) << 96, optionRecord.expiryTimestamp);
        }

        uint256 rxAmount = amount * optionRecord.underlyingAmount;
        uint256 fee = ((rxAmount / 10000) * feeBps);
        address underlyingAsset = optionRecord.underlyingAsset;

        // Transfer the requisite underlying asset
        SafeTransferLib.safeTransferFrom(ERC20(underlyingAsset), msg.sender, address(this), (rxAmount + fee));

        feeBalance[underlyingAsset] += fee;

        emit FeeAccrued(underlyingAsset, msg.sender, fee);

        return optionRecord;
    }

    function _assignExercise(uint160 optionId, uint112 amount) internal {
        // A bucket of the overall amounts written and exercised for all claims
        // on a given day
        ClaimBucket storage claimBucket;
        uint16 daysAfterOptionTypeCreation = 0;

        while (amount > 0) {
            // get the claim bucket to assign
            claimBucket = _claimBucketByOptionAndDay[optionId][daysAfterOptionTypeCreation];

            uint112 amountAvailiable = claimBucket.amountWritten - claimBucket.amountExercised;

            uint112 amountPresentlyExercised;
            if (amountAvailiable < amount) {
                amount -= amountAvailiable;
                amountPresentlyExercised = amountAvailiable;
            } else {
                amountPresentlyExercised = amount;
                amount = 0;
            }

            claimBucket.amountExercised += amountPresentlyExercised;
            daysAfterOptionTypeCreation++;
        }
    }

    function _getDaysAfterOptionCreation(Option storage optionRecord) internal view returns (uint16) {
        return uint16((block.timestamp - optionRecord.creationTimestamp) / 86400);
    }

    // TODO: gas test storage and memory
    function _getAmountExercised(
        Claim storage claimRecord,
        ClaimBucket storage claimBucket
    ) internal view returns (uint256 _exercised, uint256 _unexercised) {
        // The ratio of exercised to written options in the bucket multiplied by the
        // number of options actaully written in the claim.
        _exercised = FixedPointMathLib.mulDivDown(
            claimBucket.amountExercised, claimRecord.amountWritten, claimBucket.amountWritten
        );

        // The ration of unexercised to written options in the bucket multiplied by the
        // number of options actually written in the claim.
        _unexercised = FixedPointMathLib.mulDivDown(
            claimBucket.amountWritten - claimBucket.amountExercised,
            claimRecord.amountWritten,
            claimBucket.amountWritten
        );
    }

    function _getExerciseAndUnderlyingAssetPositions(
        Option storage optionRecord,
        Claim storage claimRecord,
        ClaimBucket storage claimBucket
    ) internal view returns (uint256 amountExerciseAsset, uint256 amountUnderlyingAsset) {
        (uint256 amountExercised, uint256 amountUnexercised) = _getAmountExercised(claimRecord, claimBucket);
        amountExerciseAsset = optionRecord.exerciseAmount * amountExercised;
        amountUnderlyingAsset = optionRecord.underlyingAmount * amountUnexercised;
    }

    // **********************************************************************
    //                    TOKEN ID ENCODING HELPERS
    // **********************************************************************
    /**
     * @dev Claim and option type ids are encoded as follows:
     * (MSb)
     * [160b hash of option data structure]
     * [96b encoding of claim id]
     * (LSb)
     * This function decodes a supplied id.
     * @return optionId claimId The decoded components of the id as described above,
     * padded as required.
     */
    function getDecodedIdComponents(uint256 id) public pure returns (uint160 optionId, uint96 claimId) {
        // grab lower 96b of id for claim id
        uint256 claimIdMask = 0xFFFFFFFFFFFFFFFFFFFFFFFF;

        // move hash to LSB to fit into uint160
        optionId = uint160(id >> 96);
        claimId = uint96(id & claimIdMask);
    }

    function getOptionFromEncodedId(uint256 id) public view returns (Option memory) {
        (uint160 optionId,) = getDecodedIdComponents(id);
        return _option[optionId];
    }

    function getTokenId(uint160 optionId, uint96 claimIndex) public pure returns (uint256 claimId) {
        claimId |= (uint256(optionId) << 96);
        claimId |= uint256(claimIndex);
    }

    function isOptionInitialized(uint160 optionId) public view returns (bool) {
        return _option[optionId].underlyingAsset != address(0x0);
    }
}
