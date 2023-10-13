// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "./SoulBoundERC721.sol";


// Custom errors
error InvalidHandle(string handle);         // An invalid handle is passed
error StakeAmountRequired();                // No stake amount is sent
error HandleNotAvailable(uint256 tokenId);  // No stake amount is sent
error NotHandleOwner(string handle);        // Only handle owner is allowed


/// @title DHandle NFT contract
/// @dev Implements the staking and auction mechanisms of the DHandle protocol
contract DHandle is SoulBoundERC721 {

    /// @dev Time in seconds to wait for a bid to close and be able to claim ownership of a handle
    uint256 private constant BID_CLOSE = 30 days;


    // INFO: A handle is the tokenId, as uint256 representation of a /[a-z0-9_-]{3,32}/ handle string


    /// @dev Staked amounts for each tokenId
    mapping(uint256 tokenId => uint256) internal _stakeOf;

    /// @dev Current pointed URI for each tokenId
    mapping(uint256 tokenId => string) internal _uriOf;

    /// @dev Current higher bidder for the tokenIds in auction
    mapping(uint256 tokenId => address) internal _bidderOf;

    /// @dev Current higher bid amount for the tokenIds in auction
    mapping(uint256 tokenId => uint256) internal _bidAmountOf;

    /// @dev Current higher bid closing timestamps for the tokenIds in auction
    mapping(uint256 tokenId => uint256) internal _bidCloseOf;


    /// @dev Initializes the contract by setting ERC721 `name` and `symbol`
    constructor() ERC721("DHandle", "DHandle") { }


    function regiter(string memory handle, string memory uri) external payable {
        mint(toTokenId(handle), uri);
    }

    function mint(uint256 tokenId, string memory uri) public payable {
        if (msg.value == 0) revert StakeAmountRequired();

        if (_ownerOf(tokenId) != address(0)) revert HandleNotAvailable(tokenId);

        _stakeOf[tokenId] += msg.value;
        _uriOf[tokenId] = uri;

        _safeMint(msg.sender, tokenId);
    }

    function update(string memory handle, string memory uri) external {
        uint256 id = _requireOwner(handle);
        _uriOf[id] = uri;
    }

    // function bid() {}

    // function claim() {}

    // function deposit() {}

    // function withdraw() {}

    // function burn() {}


    /// @dev resolve a handle to the IPFS link of its JSON metadata
    function resolve(string memory handle) external view returns (string memory) {
        return tokenURI(toTokenId(handle));
    }

    /// @dev return the IPFS link of token id JSON metadata
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _uriOf[tokenId];
    }

    /// @dev Helper function to check and convert from handle string to token id number
    function toTokenId(string memory handle) pure public returns (uint256) {
        if (checkHandle(handle) == false) revert InvalidHandle(handle);
        return uint256(toBytes32(handle));
    }

    function checkHandle(string memory handle) pure public returns (bool) {
        bool lastSpecial = false;
        bytes32  b32 = toBytes32(handle);
        for (uint256 i = 0; i < 32; i++) {
            uint8 c = uint8(b32[i]);
            if (i == 0 && (c == 0x2d || c == 0x5f)) return false;   // start with special
            if (c == 0 && lastSpecial) return false;                // end with special
            if (c == 0 && i > 2) return true;                       // end of handle with at least 3 valid chars
            if (c < 0x30 && c != 0x2d) return false;                // abaixo do '0' e diferente de '-'
            if (c > 0x39 && c < 0x61 && c != 0x5f) return false;    // acima do '9' e abaixo do 'a' e diferente do '_'
            if (c > 0x7a) return false;                             // acima do 'z'
            lastSpecial = (c == 0x2d || c == 0x5f);                 // is it a special char ('-' or '_')
        }
        return true;
    }

    function toBytes32(string memory handle) pure internal returns (bytes32 result) {
        bytes memory temp = bytes(handle);
        if (temp.length == 0 || temp.length > 32) return 0;
        assembly {
            result := mload(add(handle, 32))
        }
    }

    function _requireOwner(string memory handle) view internal returns (uint256 tokenId) {
        tokenId = toTokenId(handle);
        if (_ownerOf(tokenId) != address(msg.sender)) revert NotHandleOwner(handle);
    }
}