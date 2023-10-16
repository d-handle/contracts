// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "./SoulBoundERC721.sol";


// Custom errors
error InvalidHandle(string handle);                     // An invalid handle is passed
error StakeAmountRequired();                            // No stake amount is sent
error HandleNotAvailable(string handle);                // The handle is already registered
error InvalidFrontendAddress();                         // Frontend address is 0x0
error FailedToSendFee(address frontend, uint256 fee);   // Error transfering fee to frontend 
error NotHandleOwner(string handle);                    // Only handle owner is allowed
error NotEnoughStake(string handle, uint256 amount);    // Not enough stake to request

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


    /// @notice register a new handle if available, by staking any starting anount to it and set the initial profile uri
    function mint(string memory handle, string memory uri) external payable {
        mint(handle, uri, msg.value, address(0));
    }

    /// @notice register a new handle if available, by staking any starting anount to it and set the initial profile uri, with frontend fees
    function mint(string memory handle, string memory uri, uint256 stake, address frontend) public payable {
        if (msg.value == 0 || stake == 0) revert StakeAmountRequired();
        if (msg.value < stake) revert NotEnoughStake(handle, stake);
        if (frontend == address(0)) revert InvalidFrontendAddress();

        uint256 id = toTokenId(handle);
        if (_ownerOf(id) != address(0)) revert HandleNotAvailable(handle);

        _stakeOf[id] += stake;
        _uriOf[id] = uri;

        _safeMint(msg.sender, id);

        // Send frontend fee if any
        uint256 fee = msg.value - stake;
        if (fee > 0) {
            (bool sent, ) = frontend.call{value: fee}("");
            if (!sent) revert FailedToSendFee(frontend, fee);
        }
    }

    /// @notice update the profile uri of the handle by the owner only
    function update(string memory handle, string memory uri) external {
        uint256 id = _requireOwner(handle);
        _uriOf[id] = uri;
    }

    // function bid() {}

    // function claim() {}

    // function deposit() {}

    function withdraw(string memory handle, uint256 amount) public {
        uint256 id = _requireOwner(handle);
        _withdraw(handle, id, amount);
    }

    function _withdraw(string memory handle, uint256 tokenId, uint256 amount) internal {
        if (amount > _stakeOf[tokenId]) revert NotEnoughStake(handle, amount);
        // TODO: transfer and update stake
    }

    /// @notice unregister an handle by the owner only, and receive the staked amount
    function burn(string memory handle) external {
        uint256 id = _requireOwner(handle);
        // TODO:  Check that there's no bids
        delete _uriOf[id];
        _withdraw(handle, id, _stakeOf[id]);
        _burn(id);
    }


    /// @notice resolve a handle to the profile uri
    function resolve(string memory handle) external view returns (string memory) {
        return tokenURI(toTokenId(handle));
    }

    /// @notice return the profile uri of token
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _uriOf[tokenId];
    }

    /// @notice check and convert from handle string to token id number
    function toTokenId(string memory handle) pure public returns (uint256) {
        if (checkHandle(handle) == false) revert InvalidHandle(handle);
        return uint256(toBytes32(handle));
    }

    /// @notice check if a handle is valid
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

    /// @dev convert from handle string to bytes32
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