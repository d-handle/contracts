// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "./SoulBoundERC721.sol";


/// @title DHandle NFT contract
/// @dev Implements the staking and auction mechanisms of the DHandle protocol
contract DHandle is SoulBoundERC721 {

    // Events
    event Minted(address owner, string handle, uint256 stake, string uri, uint256 fee, address frontend);
    event Updated(address owner, string handle, string uri);
    event Deposited(address from, string handle, uint256 amount);
    event Withdrawn(address to, string handle, uint256 amount);
    event Bid(address from, string handle, uint256 amount, uint256 time, uint256 fee, address frontend);
    event Covered(address from, string handle, uint256 amount, uint256 time);
    event Retracted(address from, string handle, uint256 time, uint256 refund, uint256 penalty);
    event Claimed(address from, string handle, string uri, uint256 time, uint256 refund, address to);
    event Burned(address from, string handle, uint256 time, uint256 refund);

    // Custom errors
    error InvalidHandle(string handle);                         // An invalid handle is passed
    error EthAmountRequired();                                  // No eth amount is sent
    error InvalidEthAmount(uint256 required, uint256 amount);   // Not the required eth amount
    error HandleNotAvailable(string handle);                    // The handle is already registered
    error HandleNotRegistered(string handle);                   // The handle is not registered
    error AuctionOngoing();                                     // There is an auction ongoing
    error AuctionClosed();                                      // The current auction is closed
    error ClaimExpired();                                       // The claim period has expired
    error NotWinningBidder(address from, address bidder);       // Not the winning bidder
    error AlreadyBidded(address bidder);                        // The current bidder cannot bid again
    error InvalidFrontendAddress();                             // Frontend address is 0x0
    error FailedToTransfer(address to, uint256 amount);         // Error transfering fee to frontend
    error NotHandleOwner(string handle);                        // Only handle owner is allowed


    /// @dev Time in seconds to wait for an auction to close and be able to claim ownership of a handle
    uint256 private constant AUCTION_WINDOW = 30 days;

    /// @dev Time in seconds to claim ownership of a handle after auction closed
    uint256 private constant CLAIM_WINDOW = 3 days;

    /// @dev Time in seconds to wait for an handle to become available after burning
    uint256 private constant HOLD_WINDOW = 90 days;


    // INFO: A handle is the tokenId, as uint256 representation of a /[a-z0-9_-]{3,32}/ handle string


    /// @dev Staked amounts for each tokenId
    mapping(uint256 tokenId => uint256) internal _stakeOf;

    /// @dev Current pointed URI for each tokenId
    mapping(uint256 tokenId => string) internal _uriOf;

    /// @dev Current timestamps for the tokenIds on hold
    mapping(uint256 tokenId => uint256) internal _holdOf;

    /// @dev Current higher bidder for the tokenIds in auction
    mapping(uint256 tokenId => address) internal _bidderOf;

    /// @dev Current higher bid amount for the tokenIds in auction
    mapping(uint256 tokenId => uint256) internal _bidAmountOf;

    /// @dev Current higher bid timestamps for the tokenIds in auction
    mapping(uint256 tokenId => uint256) internal _bidTimeOf;


    /// @dev Initializes the contract by setting ERC721 `name` and `symbol`
    constructor() ERC721("DHandle", "DHandle") { }

    // Interface functions ----------

    /// @notice register a new handle if available, by staking any starting amount to it and set the initial profile uri
    function mint(string memory handle, string memory uri) external payable {
        mint(handle, uri, msg.value, address(0));
    }

    /// @notice register a new handle if available, by staking any starting amount to it and set the initial profile uri, with frontend fees
    function mint(string memory handle, string memory uri, uint256 amount, address frontend) public payable {
        uint256 id = toTokenId(handle);
        if (!_isAvailable(id)) revert HandleNotAvailable(handle);

        _safeMint(msg.sender, id);
        _uriOf[id] = uri;

        (,uint256 fee) = _deposit(id, amount, frontend);

        emit Minted(msg.sender, handle, amount, uri, fee, frontend);
    }

    /// @notice update the profile uri of the handle by the owner only
    function update(string memory handle, string memory uri) external {
        uint256 id = _requireOwner(handle);
        _uriOf[id] = uri;

        emit Updated(msg.sender, handle, uri);
    }

    /// @notice place a bid in a handle
    function bid(string memory handle) external payable {
        bid(handle, msg.value, address(0));
    }

    /// @notice place a bid in a handle, with frontend fees
    function bid(string memory handle, uint256 amount, address frontend) public payable {
        if (msg.value == 0 || amount == 0) revert EthAmountRequired();
        if (frontend == address(0) && msg.value != amount) revert InvalidFrontendAddress();
        if (msg.value < amount) revert InvalidEthAmount(amount, msg.value);
        uint256 id = toTokenId(handle);
        if (!_isRegistered(id)) revert HandleNotRegistered(handle);
        if (_canClaim(id)) revert AuctionClosed();  // during claim window no bids accepted
        if (_bidderOf[id] == msg.sender) revert AlreadyBidded(msg.sender);
        uint256 bidValue = _stakeOrBidOf(id) * 2;
        if (amount != bidValue) revert InvalidEthAmount(bidValue, amount);

        // save old bid data
        address oldBidder = _bidderOf[id];
        uint256 oldAmount = _bidAmountOf[id];
        // place new bid
        _bidderOf[id] = msg.sender;
        _bidAmountOf[id] = amount;
        _bidTimeOf[id] = block.timestamp;
        // refund old bidder if any
        if (oldBidder != address(0)) _transferEth(oldBidder, oldAmount, id);
        // send frontend fee if any
        uint256 fee = msg.value - amount;
        if (fee > 0) _transferEth(frontend, fee, id);

        emit Bid(msg.sender, handle, amount, block.timestamp, fee, frontend);
    }

    /// @notice cancel a bid by the bidder, if after the auction closed the full bid amount will be returned, otherwise only the proportional full days passed
    /// of the auction window will be returned to the bidder, the remaining will be added to the stake of the current owner
    // function retract() {}

    /// @notice claim the handle from current owner if auction closed and return current owner stake
    function claim(string memory handle, string memory uri) external {
        uint256 id = toTokenId(handle);
        address bidder = _bidderOf[id];
        if (bidder != msg.sender) revert NotWinningBidder(msg.sender, bidder);
        if (_isAuctionOpen(id)) revert AuctionOngoing();
        if (!_canClaim(id)) revert ClaimExpired();

        // save old owner data
        address oldOwner = _ownerOf(id);
        uint256 oldStake = _stakeOf[id];
        // accept new owner 
        _update(_bidderOf[id], id, address(0));
        _stakeOf[id] = _bidAmountOf[id];
        // cleanup the bid
        delete _bidderOf[id];
        delete _bidAmountOf[id];
        delete _bidTimeOf[id];
        // refund old owner
        _transferEth(oldOwner, oldStake, id);

        emit Claimed(msg.sender, handle, uri, block.timestamp, oldStake, oldOwner);
    }

    /// @notice returns the current staked amount (or higher bid if any) for this handle
    function stakeOf(string memory handle) public view returns (uint256 stake) {
        uint256 id = toTokenId(handle);
        stake = _stakeOrBidOf(id);
    }

    /// @notice returns if the current bid is still valid
    function isBidValid(string memory handle) external view returns (bool) {
        uint256 id = toTokenId(handle);
        return _isBidValid(id);
    }

    /// @notice returns if the current auction is still open
    function isAuctionOpen(string memory handle) external view returns (bool) {
        uint256 id = toTokenId(handle);
        return _isAuctionOpen(id);
    }

    /// @notice returns if the current bidder can claim the handle
    function canClaim(string memory handle) external view returns (bool) {
        uint256 id = toTokenId(handle);
        return _canClaim(id);
    }

    /// @notice check if a handle is on hold after burn
    function isOnHold(string memory handle) external view returns (bool) {
        uint256 id = toTokenId(handle);
        return _isOnHold(id);
    }

    /// @notice check if a handle is registered
    function isRegistered(string memory handle) external view returns (bool) {
        uint256 id = toTokenId(handle);
        return _isRegistered(id);
    }

    /// @notice check if a handle is available to mint
    function isAvailable(string memory handle) external view returns (bool) {
        uint256 id = toTokenId(handle);
        return _isAvailable(id);
    }

    /// @notice deposit more stake into an handle
    function deposit(string memory handle) external payable {
        uint256 id = toTokenId(handle);
        if (_ownerOf(id) == address(0)) revert HandleNotRegistered(handle);

        (bool covered, ) = _deposit(id, msg.value, address(0));

        emit Deposited(msg.sender, handle, msg.value);
        if (covered) emit Covered(msg.sender, handle, _stakeOf[id], block.timestamp);
    }

    function withdraw(string memory handle, uint256 amount) external {
        uint256 id = _requireOwner(handle);
        uint256 stake = _stakeOf[id];
        if (amount >= stake) revert InvalidEthAmount(stake, amount);

        _withdraw(id, amount);

        emit Withdrawn(msg.sender, handle, amount);
    }

    /// @notice unregister an handle by the owner only, and refund the staked amount
    function burn(string memory handle) external {
        uint256 id = _requireOwner(handle);

        delete _uriOf[id];
        _burn(id);
        uint256 refund = _stakeOf[id];
        _withdraw(id, refund);

        emit Burned(msg.sender, handle, block.timestamp, refund);
    }

    /// @notice resolve a handle to the profile uri
    function resolve(string memory handle) external view returns (string memory) {
        uint256 id = toTokenId(handle);
        if (_ownerOf(id) == address(0)) revert HandleNotRegistered(handle);
        return _uriOf[id];
    }

    /// @notice return the profile uri of token
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);     // from ERC721 implementation
        return _uriOf[tokenId];
    }

    // Helper functions ----------

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

    // Internal functions ----------

    /// @dev internal deposit logic to reuse in external operations
    function _deposit(uint256 tokenId, uint256 amount, address frontend) internal returns (bool covered, uint256 fee) {
        if (msg.value == 0 ) revert EthAmountRequired();
        if (msg.value < amount) revert InvalidEthAmount(amount, msg.value);
        if (frontend == address(0) && msg.value != amount) revert InvalidFrontendAddress();

        _stakeOf[tokenId] += amount;

        // check if deposit covers the current bid, and return bid
        covered = _isBidValid(tokenId) && _stakeOf[tokenId] >= _bidAmountOf[tokenId];
        if (covered) {
            // save bid data
            address bidder = _bidderOf[tokenId];
            uint256 bidAmount = _bidAmountOf[tokenId];
            // cleanup bid
            delete _bidderOf[tokenId];
            delete _bidAmountOf[tokenId];
            delete _bidTimeOf[tokenId];
            // refund bidder
            _transferEth(bidder, bidAmount, tokenId);
        }

        // Send frontend fee if any
        fee = msg.value - amount;
        if (fee > 0) _transferEth(frontend, fee, tokenId);
    }

    /// @dev internal withdraw logic to reuse in external operations
    function _withdraw(uint256 tokenId, uint256 amount) internal {
        // check that there's no ongoing bids
        if (_isBidValid(tokenId)) revert AuctionOngoing();
        // transfer and update stake (leave checked)
        _stakeOf[tokenId] -= amount;
        if (!_transferEth(msg.sender, amount)) revert FailedToTransfer(msg.sender, amount);
    }

    /// @dev internal to return the current staked amount, or higher bid if any, for this token id
    function _stakeOrBidOf(uint256 tokenId) internal view returns (uint256 stake) {
        stake = _isBidValid(tokenId) ? _bidAmountOf[tokenId] : _stakeOf[tokenId];
    }

    /// @dev internal to check if current bid is still valid
    function _isBidValid(uint256 tokenId) internal view returns (bool) {
        return _bidderOf[tokenId] != address(0) && block.timestamp <= (_bidTimeOf[tokenId] + AUCTION_WINDOW + CLAIM_WINDOW);
    }

    /// @dev internal to check if current auction is still open
    function _isAuctionOpen(uint256 tokenId) internal view returns (bool) {
        return _bidderOf[tokenId] != address(0) && block.timestamp <= (_bidTimeOf[tokenId] + AUCTION_WINDOW);
    }

    /// @dev internal to check if current auction is still open
    function _canClaim(uint256 tokenId) internal view returns (bool) {
        return _bidderOf[tokenId] != address(0) && block.timestamp > (_bidTimeOf[tokenId] + AUCTION_WINDOW) && block.timestamp <= (_bidTimeOf[tokenId] + AUCTION_WINDOW + CLAIM_WINDOW);
    }

    function _isOnHold(uint256 tokenId) internal view returns (bool) {
        return block.timestamp <= _holdOf[tokenId] + HOLD_WINDOW;
    }

    function _isRegistered(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function _isAvailable(uint256 tokenId) internal view returns (bool) {
        return !_isRegistered(tokenId) && !_isOnHold(tokenId);
    }


    /// @dev internal requires handle owner or otherwise reverts
    function _requireOwner(string memory handle) view internal returns (uint256 tokenId) {
        tokenId = toTokenId(handle);
        if (_ownerOf(tokenId) != address(msg.sender)) revert NotHandleOwner(handle);
    }

    /// @dev transfer ETH to another account
    function _transferEth(address to, uint256 amount) internal returns (bool sent) {
        sent = _transferEth(to, amount, 0);
    }

    /// @dev transfer ETH to another account
    function _transferEth(address to, uint256 amount, uint256 fallbackId) internal returns (bool sent) {
        (sent, ) = to.call{value: amount}("");
         if (!sent && fallbackId != 0) {
            // fee transfer failed, so add it to stake instead
            _stakeOf[fallbackId] += amount;
        }
   }

   /// @dev internal convertion from handle string to bytes32
    function toBytes32(string memory handle) pure internal returns (bytes32 result) {
        bytes memory temp = bytes(handle);
        if (temp.length == 0 || temp.length > 32) return 0;
        assembly {
            result := mload(add(handle, 32))
        }
    }
}