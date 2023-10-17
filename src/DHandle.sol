// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "./SoulBoundERC721.sol";


// Custom errors
error InvalidHandle(string handle);                         // An invalid handle is passed
error EthAmountRequired();                                  // No eth amount is sent
error InvalidEthAmount(uint256 required, uint256 amount);   // Not the required eth amount
error HandleNotAvailable(string handle);                    // The handle is already registered
error HandleNotRegistered(string handle);                   // The handle is not registered
error InvalidToAddress();                                   // To address is 0x0
error InvalidFrontendAddress();                             // Frontend address is 0x0
error FailedToTransfer(address to, uint256 amount);         // Error transfering fee to frontend
error NotHandleOwner(string handle);                        // Only handle owner is allowed

/// @title DHandle NFT contract
/// @dev Implements the staking and auction mechanisms of the DHandle protocol
contract DHandle is SoulBoundERC721 {

    /// @dev Time in seconds to wait for an auction to close and be able to claim ownership of a handle
    uint256 private constant AUCTION_WINDOW = 30 days;

    /// @dev Time in seconds to claim ownership of a handle after auction closed
    uint256 private constant CLAIM_WINDOW = 3 days;


    // INFO: A handle is the tokenId, as uint256 representation of a /[a-z0-9_-]{3,32}/ handle string


    /// @dev Staked amounts for each tokenId
    mapping(uint256 tokenId => uint256) internal _stakeOf;

    /// @dev Current pointed URI for each tokenId
    mapping(uint256 tokenId => string) internal _uriOf;

    /// @dev Current higher bidder for the tokenIds in auction
    mapping(uint256 tokenId => address) internal _bidderOf;

    /// @dev Current higher bid amount for the tokenIds in auction
    mapping(uint256 tokenId => uint256) internal _bidAmountOf;

    /// @dev Current higher bid timestamps for the tokenIds in auction
    mapping(uint256 tokenId => uint256) internal _bidTimeOf;


    /// @dev Initializes the contract by setting ERC721 `name` and `symbol`
    constructor() ERC721("DHandle", "DHandle") { }


    /// @notice register a new handle if available, by staking any starting amount to it and set the initial profile uri
    function mint(address to, string memory handle, string memory uri) external payable {
        mint(to, handle, uri, msg.value, address(0));
    }

    /// @notice register a new handle if available, by staking any starting amount to it and set the initial profile uri, with frontend fees
    function mint(address to, string memory handle, string memory uri, uint256 amount, address frontend) public payable {
        if (to == address(0)) revert InvalidToAddress();

        uint256 id = toTokenId(handle);
        if (_ownerOf(id) != address(0)) revert HandleNotAvailable(handle);

        _safeMint(to, id);
        _uriOf[id] = uri;

        _deposit(id, amount, frontend);
    }

    /// @notice update the profile uri of the handle by the owner only
    function update(string memory handle, string memory uri) external {
        uint256 id = _requireOwner(handle);
        _uriOf[id] = uri;
    }

    /// @notice place a bid in a handle
    function bid(string memory handle) external payable {
        bid(handle, msg.value, address(0));
    }

    /// @notice place a bid in a handle, with frontend fees
    function bid(string memory handle, uint256 amount, address frontend) public payable {
        // TODO: during claim window no bids accepted
        uint256 id = _requireOwner(handle);
        if (msg.value == 0 || amount == 0) revert EthAmountRequired();
        uint256 bidValue = _stakeOrBidOf(id) * 2;
        if (amount != bidValue) revert InvalidEthAmount(bidValue, amount);
        if (msg.value < amount) revert InvalidEthAmount(amount, msg.value);
        if (frontend == address(0) && msg.value != amount) revert InvalidFrontendAddress();
        // TODO: refund current bid, if any, and place new bid
    }

    /// @notice cancel a bid by the bidder, if after the auction closed the full bid amount will be returned, otherwise only the proportional full days passed
    /// of the auction window will be returned to the bidder
    // function retract() {}

    /// @notice claim the handle from current owner if auction closed and return current owner stake
    // function claim() {}

    /// @notice returns the current staked amount (or higher bid if any) for this handle
    function stakeOf(string memory handle) public view returns (uint256 stake) {
        uint256 id = toTokenId(handle);
        stake = _stakeOrBidOf(id);
    }

    /// @dev internal to return the current staked amount, or higher bid if any, for this token id
    function _stakeOrBidOf(uint256 tokenId) internal view returns (uint256 stake) {
        stake = _isBidValid(tokenId) ? _bidAmountOf[tokenId] : _stakeOf[tokenId];
    }

    /// @notice returns if the current bid is still valid
    function isBidValid(string memory handle) external view returns (bool) {
        uint256 id = toTokenId(handle);
        return _isBidValid(id);
    }

    /// @dev internal to check if current bid is still valid
    function _isBidValid(uint256 tokenId) internal view returns (bool) {
        return _bidderOf[tokenId] != address(0) && block.timestamp <= (_bidTimeOf[tokenId] + AUCTION_WINDOW + CLAIM_WINDOW);
    }

    /// @notice returns if the current auction is still open
    function isAuctionOpen(string memory handle) external view returns (bool) {
        uint256 id = toTokenId(handle);
        return _isAuctionOpen(id);
    }

    /// @dev internal to check if current auction is still open
    function _isAuctionOpen(uint256 tokenId) internal view returns (bool) {
        return _bidderOf[tokenId] != address(0) && block.timestamp <= (_bidTimeOf[tokenId] + AUCTION_WINDOW);
    }

    /// @notice returns if the current bidder can claim the handle
    function canClaim(string memory handle) external view returns (bool) {
        uint256 id = toTokenId(handle);
        return _canClaim(id);
    }

    /// @dev internal to check if current auction is still open
    function _canClaim(uint256 tokenId) internal view returns (bool) {
        return _bidderOf[tokenId] != address(0) && block.timestamp > (_bidTimeOf[tokenId] + AUCTION_WINDOW) && block.timestamp <= (_bidTimeOf[tokenId] + AUCTION_WINDOW + CLAIM_WINDOW);
    }

    /// @notice deposit more stake into an handle
    function deposit(string memory handle) external payable {
        deposit(handle, msg.value, address(0));
    }

    /// @notice deposit more stake into an handle, with frontend fees
    function deposit(string memory handle, uint256 amount, address frontend) public payable {
        uint256 id = toTokenId(handle);
        if (_ownerOf(id) == address(0)) revert HandleNotRegistered(handle);

        _deposit(id, amount, frontend);
    }

    /// @dev internal deposit logic to reuse in external operations
    function _deposit(uint256 id, uint256 amount, address frontend) internal {
        if (msg.value == 0 || amount == 0) revert EthAmountRequired();
        if (msg.value < amount) revert InvalidEthAmount(amount, msg.value);
        if (frontend == address(0) && msg.value != amount) revert InvalidFrontendAddress();

        _stakeOf[id] += amount;
        // TODO: check if deposit covers the current bid, and return bid

        // Send frontend fee if any
        uint256 fee = msg.value - amount;
        if (fee > 0) {
            (bool sent, ) = frontend.call{value: fee}("");
            if (!sent) revert FailedToTransfer(frontend, fee);
        }
    }

    function withdraw(address to, string memory handle, uint256 amount) external {
        uint256 id = _requireOwner(handle);
        uint256 stake = _stakeOf[id];
        if (amount >= stake) revert InvalidEthAmount(stake, amount);
        _withdraw(to, id, amount);
    }

    /// @dev internal withdraw logic to reuse in external operations
    function _withdraw(address to, uint256 tokenId, uint256 amount) internal {
        // TODO:  Check that there's no ongoing bids
        // transfer and update stake
        _stakeOf[tokenId] -= amount;
        (bool sent, ) = to.call{value: amount}("");
        if (!sent) revert FailedToTransfer(to, amount);
    }

    /// @notice unregister an handle by the owner only, and receive the staked amount
    function burn(address to, string memory handle) external {
        uint256 id = _requireOwner(handle);
        delete _uriOf[id];
        _withdraw(to, id, _stakeOf[id]);
        _burn(id);
    }

    /// @notice check if a handle is available to mint
    function isAvailable(string memory handle) external view returns (bool) {
        return _ownerOf(toTokenId(handle)) == address(0);
    }

    /// @notice resolve a handle to the profile uri
    function resolve(string memory handle) external view returns (string memory) {
        return tokenURI(toTokenId(handle));
    }

    /// @notice return the profile uri of token
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);     // from ERC721 implementation
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

    /// @dev internal convertion from handle string to bytes32
    function toBytes32(string memory handle) pure internal returns (bytes32 result) {
        bytes memory temp = bytes(handle);
        if (temp.length == 0 || temp.length > 32) return 0;
        assembly {
            result := mload(add(handle, 32))
        }
    }

    /// @dev internal requires handle owner or otherwise reverts
    function _requireOwner(string memory handle) view internal returns (uint256 tokenId) {
        tokenId = toTokenId(handle);
        if (_ownerOf(tokenId) != address(msg.sender)) revert NotHandleOwner(handle);
    }
}