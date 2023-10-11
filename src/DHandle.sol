// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "./SoulBoundERC721.sol";

/// @title DHandle NFT contract
/// @dev Implements the staking and auction mechanisms of the DHandle protocol
contract DHandle is SoulBoundERC721 {

    // @dev Time in seconds to wait for a bid to close and be able to claim ownership of a handle
    uint256 private constant BID_CLOSE = 30 days;

    /// @info An handle is the tokenId, as uint256 representation of a /[a-z0-9_-]{3,32}/ handle string

    /// @dev Staked amounts for each handle
    mapping(uint256 handle => uint256) internal _stakeOf;

    /// @dev Current pointed URI for each handle
    mapping(uint256 handle => string) internal _uriOf;

    /// @dev Current higher bidder for the handles in auction
    mapping(uint256 handle => address) internal _bidderOf;

    /// @dev Current higher bid amount for the handles in auction
    mapping(uint256 handle => uint256) internal _bidAmountOf;

    /// @dev Current higher bid closing timestamps for the handles in auction
    mapping(uint256 handle => uint256) internal _bidCloseOf;

    /// @dev Initializes the contract by setting ERC721 `name` and `symbol`
    constructor() ERC721("DHandle", "DHandle") { }

    // function mint() {}

    // function update() {}

    // function bid() {}

    // function claim() {}

    // function deposit() {}

    // function withdraw() {}

    // function burn() {}


    /// @dev resolve a handle to the IPFS link of its JSON metadata
    function tokenURI(uint256 handle) public view override returns (string memory) {
        _requireOwned(handle);
        return _uriOf[handle];
    }
}