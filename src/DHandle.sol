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
    event Bidden(address from, string handle, uint256 amount, uint256 time, uint256 fee, address frontend);
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
    error InvalidIndexRange(uint256 start, uint256 end);        // Range of indexes out of bounds


    /// @dev Time in seconds to wait for an auction to close and be able to claim ownership of a handle
    uint128 private constant AUCTION_WINDOW = 30 days;

    /// @dev Time in seconds to claim ownership of a handle after auction closed
    uint128 private constant CLAIM_WINDOW = 3 days;

    /// @dev Time in seconds to wait for an handle to become available after burning
    uint128 private constant HOLD_WINDOW = 90 days;


    /// @notice structure to store handle registration data
    struct Reg {
        uint128 stake;
        uint128 time;
        string uri;
    }

    /// @notice structure to store auction bid data
    struct Bid {
        uint128 amount;
        uint128 time;
        address bidder;
    }

    /// @notice structure to return handle data (registrations or auctions) to the frontends
    struct HandleData {
        uint128 amount;
        uint128 time;
        address actor;
        string handle;
    }


    // INFO: A handle is the tokenId, as uint256 representation of a /[a-z0-9_-]{3,32}/ handle string


    // Storage ----------

    /// @dev registration data for each tokenId
    mapping(uint256 tokenId => Reg) private _regs;

    /// @dev Current higher bidder for the tokenIds in auction
    mapping(uint256 tokenId => Bid) private _bids;

    /// @dev Current timestamps for the tokenIds on hold
    mapping(uint256 tokenId => uint128) private _holds;

    /// @dev List of handles currently in auction for frontends (might include expired auctions, always check)
    uint256[] private _auctions;


    // Constructor ----------

    /// @dev Initializes the contract by setting ERC721 `name` and `symbol`
    constructor() ERC721("DHandle", "DHandle") { }

    // Interface functions ----------

    /// @notice register a new handle if available, by staking any starting amount to it and set the initial profile uri
    function mint(string memory handle, string memory uri) external payable {
        mint(handle, uri, uint128(msg.value), address(0));
    }

    /// @notice register a new handle if available, by staking any starting amount to it and set the initial profile uri, with frontend fees
    function mint(string memory handle, string memory uri, uint128 amount, address frontend) public payable {
        uint256 id = toTokenId(handle);
        if (!_isAvailable(id)) revert HandleNotAvailable(handle);

        _safeMint(msg.sender, id);
        _regs[id].time = uint128(block.timestamp);
        _regs[id].uri = uri;
        delete _holds[id];

        (,uint256 fee) = _deposit(id, amount, frontend);

        emit Minted(msg.sender, handle, amount, uri, fee, frontend);
    }

    /// @notice update the profile uri of the handle by the owner only
    function update(string memory handle, string memory uri) external {
        uint256 id = _requireOwner(handle);
        _regs[id].uri = uri;

        emit Updated(msg.sender, handle, uri);
    }

    /// @notice place a bid in a handle
    function bid(string memory handle) external payable {
        bid(handle, uint128(msg.value), address(0));
    }

    /// @notice place a bid in a handle, with frontend fees
    function bid(string memory handle, uint128 amount, address frontend) public payable {
        if (msg.value == 0 || amount == 0) revert EthAmountRequired();
        if (frontend == address(0) && msg.value != amount) revert InvalidFrontendAddress();
        if (msg.value < amount) revert InvalidEthAmount(amount, msg.value);
        uint256 id = toTokenId(handle);
        if (!_isRegistered(id)) revert HandleNotRegistered(handle);
        if (_canClaim(id)) revert AuctionClosed();  // during claim window no bids accepted
        if (_bids[id].bidder == msg.sender) revert AlreadyBidded(msg.sender);
        uint256 bidValue = _stakeOrBidOf(id) * 2;
        if (amount != bidValue) revert InvalidEthAmount(bidValue, amount);

        // save old bid data
        address oldBidder = _bids[id].bidder;
        uint128 oldAmount = _bids[id].amount;
        // place new bid
        if (oldBidder == address(0)) _auctions.push(id);
        _bids[id].bidder = msg.sender;
        _bids[id].amount = amount;
        _bids[id].time = uint128(block.timestamp);
        // refund old bidder if any
        if (oldBidder != address(0)) _transferEth(oldBidder, oldAmount, id);
        // send frontend fee if any
        uint128 fee = uint128(msg.value) - amount;
        if (fee > 0) _transferEth(frontend, fee, id);

        emit Bidden(msg.sender, handle, amount, block.timestamp, fee, frontend);
    }

    /// @notice cancel a bid by the bidder, if after the auction closed the full bid amount will be returned, otherwise only the proportional full days passed
    /// of the auction window will be returned to the bidder, the remaining will be added to the stake of the current owner
    function retract(string memory handle) public payable {
        retract(handle, address(0));
    }

    /// @notice cancel a bid by the bidder, if after the auction closed the full bid amount will be returned, otherwise only the proportional full days passed
    /// of the auction window will be returned to the bidder, the remaining will be added to the stake of the current owner
    function retract(string memory handle, address frontend) public payable {
        uint256 id = toTokenId(handle);
        address bidder = _bids[id].bidder;
        if (bidder != msg.sender) revert NotWinningBidder(msg.sender, bidder);
        if (frontend == address(0) && msg.value != 0) revert InvalidFrontendAddress();
        uint128 bidValue = _bids[id].amount;
        uint128 penalty;
        uint128 refund;
        if (_isAuctionOpen(id)) {
            penalty = bidValue * ((_bids[id].time + AUCTION_WINDOW - uint128(block.timestamp)) / 1 days) / (AUCTION_WINDOW / 1 days);
            refund = bidValue - penalty;
        } else {
            penalty = 0;
            refund = bidValue;
        }
        // add penalty to stake if any
        if (penalty > 0) _regs[id].stake += penalty;
        // cleanup the bid
        _deleteBid(id);
        // refund bidder
        _transferEth(bidder, refund, id);

        // send frontend fee if any
        if (msg.value > 0) _transferEth(frontend, uint128(msg.value), id);

        emit Retracted(msg.sender, handle, block.timestamp, refund, penalty);
    }

    /// @notice claim the handle from current owner if auction closed and return current owner stake
    function claim(string memory handle, string memory uri) external {
        uint256 id = toTokenId(handle);
        address bidder = _bids[id].bidder;
        if (bidder != msg.sender) revert NotWinningBidder(msg.sender, bidder);
        if (_isAuctionOpen(id)) revert AuctionOngoing();
        if (!_canClaim(id)) revert ClaimExpired();

        // save old owner data
        address oldOwner = _ownerOf(id);
        uint128 oldStake = _regs[id].stake;
        // accept new owner 
        _update(_bids[id].bidder, id, address(0));
        _regs[id].stake = _bids[id].amount;
        // cleanup the bid
        _deleteBid(id);
        // refund old owner
        _transferEth(oldOwner, oldStake, id);

        emit Claimed(msg.sender, handle, uri, block.timestamp, oldStake, oldOwner);
    }

    /// @notice returns the current staked amount for this handle
    function stakeOf(string memory handle) public view returns (uint256 stake) {
        uint256 id = toTokenId(handle);
        stake = _regs[id].stake;
    }

    /// @notice returns the current bid amount for this handle
    function bidOf(string memory handle) public view returns (uint256 stake) {
        uint256 id = toTokenId(handle);
        stake = _bids[id].amount;
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

        (bool covered, ) = _deposit(id, uint128(msg.value), address(0));

        emit Deposited(msg.sender, handle, msg.value);
        if (covered) emit Covered(msg.sender, handle, _regs[id].stake, block.timestamp);
    }

    /// @notice withdraw stake from a handle
    function withdraw(string memory handle, uint128 amount) external {
        uint256 id = _requireOwner(handle);
        uint256 stake = _regs[id].stake;
        if (amount >= stake) revert InvalidEthAmount(stake, amount);

        // withdraw if no valid bids
        _withdraw(id, amount);

        emit Withdrawn(msg.sender, handle, amount);
    }

    /// @notice unregister an handle by the owner only, and refund the staked amount
    function burn(string memory handle) external {
        uint256 id = _requireOwner(handle);

        delete _regs[id];
        _burn(id);
        uint128 refund = _regs[id].stake;
        _holds[id] = uint128(block.timestamp);

        // refund if there's a stalled bid (not active)
        if (_bids[id].bidder != address(0)) {
            // save bid data and delete
            address bidder = _bids[id].bidder;
            uint128 amount = _bids[id].amount;
            _deleteBid(id);
            // refund bidder
            _transferEth(bidder, amount, id);
        }
        // withdraw if no valid bids
        _withdraw(id, refund);

        emit Burned(msg.sender, handle, block.timestamp, refund);
    }

    /// @notice resolve a handle to the profile uri
    function resolve(string memory handle) external view returns (string memory) {
        uint256 id = toTokenId(handle);
        if (_ownerOf(id) == address(0)) revert HandleNotRegistered(handle);
        return _regs[id].uri;
    }

    /// @notice return total auctions 
    function auctions() external view returns (uint256) {
        return _auctions.length;
    }

    /// @notice return auction range to frontends
    function auctionRange(uint256 start, uint256 end) external view returns (HandleData[] memory range) {
        if (start > end || end >= _auctions.length) revert InvalidIndexRange(start, end);

        uint256 len = end - start + 1;
        range = new HandleData[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 id = _auctions[start + i];
            range[i] = HandleData({
                amount: _bids[id].amount,
                time:   _bids[id].time,
                actor:  _bids[id].bidder,
                handle: toHandle(id)
            });
        }
    }

    /// @notice return handle data to frontends
    function handleData(uint256 tokenId) external view returns (HandleData memory) {
        return handleData(toHandle(tokenId));
    }

    function handleData(string memory handle) public view returns (HandleData memory) {
        uint256 id = toTokenId(handle);
        if (!_isRegistered(id)) revert HandleNotRegistered(handle);

        return HandleData({
            amount: _regs[id].stake,
            time:   _regs[id].time,
            actor:  _ownerOf(id),
            handle: handle
        });
    }

    /// @notice return the profile uri of token
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);     // from ERC721 implementation
        return _regs[tokenId].uri;
    }

    // Helper functions ----------

    /// @notice convert from token id number to handle string
    function toHandle(uint256 tokenId) pure public returns (string memory handle) {
        handle = string(abi.encodePacked(bytes32(tokenId)));
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

    // Internal functions ----------

    /// @dev internal deposit logic to reuse in external operations
    function _deposit(uint256 tokenId, uint128 amount, address frontend) internal returns (bool covered, uint128 fee) {
        if (msg.value == 0 ) revert EthAmountRequired();
        if (msg.value < amount) revert InvalidEthAmount(amount, msg.value);
        if (frontend == address(0) && msg.value != amount) revert InvalidFrontendAddress();

        _regs[tokenId].stake += amount;

        // check if deposit covers the current bid, and return bid
        covered = _isBidValid(tokenId) && _regs[tokenId].stake >= _bids[tokenId].amount;
        if (covered) {
            // save bid data
            address bidder = _bids[tokenId].bidder;
            uint128 bidAmount = _bids[tokenId].amount;
            // cleanup bid
            _deleteBid(tokenId);
            // refund bidder
            _transferEth(bidder, bidAmount, tokenId);
        }

        // Send frontend fee if any
        fee = uint128(msg.value) - amount;
        if (fee > 0) _transferEth(frontend, fee, tokenId);
    }

    /// @dev internal withdraw logic to reuse in external operations
    function _withdraw(uint256 tokenId, uint128 amount) internal {
        // check that there's no ongoing bids
        if (_isBidValid(tokenId)) revert AuctionOngoing();
        // transfer and update stake (leave checked)
        _regs[tokenId].stake -= amount;
        if (!_transferEth(msg.sender, amount)) revert FailedToTransfer(msg.sender, amount);
    }

    /// @dev internal to return the current staked amount, or higher bid if any, for this token id
    function _stakeOrBidOf(uint256 tokenId) internal view returns (uint256 stake) {
        stake = _isBidValid(tokenId) ? _bids[tokenId].amount : _regs[tokenId].stake;
    }

    /// @dev internal to check if current bid is still valid
    function _isBidValid(uint256 tokenId) internal view returns (bool) {
        return _bids[tokenId].bidder != address(0) && block.timestamp <= (_bids[tokenId].time + AUCTION_WINDOW + CLAIM_WINDOW);
    }

    /// @dev internal to check if current auction is still open
    function _isAuctionOpen(uint256 tokenId) internal view returns (bool) {
        return _bids[tokenId].bidder != address(0) && block.timestamp <= (_bids[tokenId].time + AUCTION_WINDOW);
    }

    /// @dev internal to check if current auction is still open
    function _canClaim(uint256 tokenId) internal view returns (bool) {
        return _bids[tokenId].bidder != address(0) && block.timestamp > (_bids[tokenId].time + AUCTION_WINDOW) && block.timestamp <= (_bids[tokenId].time + AUCTION_WINDOW + CLAIM_WINDOW);
    }

    /// @dev internal to check if handle is on hold after burn
    function _isOnHold(uint256 tokenId) internal view returns (bool) {
        return block.timestamp <= _holds[tokenId] + HOLD_WINDOW;
    }

    /// @dev internal to check if handle is registered
    function _isRegistered(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @dev internal to check if handle is available to mint
    function _isAvailable(uint256 tokenId) internal view returns (bool) {
        return !_isRegistered(tokenId) && !_isOnHold(tokenId);
    }

    /// @dev internal requires handle owner or otherwise reverts
    function _requireOwner(string memory handle) view internal returns (uint256 tokenId) {
        tokenId = toTokenId(handle);
        if (_ownerOf(tokenId) != address(msg.sender)) revert NotHandleOwner(handle);
    }

    function _deleteBid(uint256 tokenId) internal {
        delete _bids[tokenId];
        uint256 last = _auctions.length - 1;
        for (uint256 i = last; i >= 0; i--) {
            if (_auctions[i] == tokenId) {
                _auctions[i] = _auctions[last];
                _auctions.pop();
                break;
            }
        }
    }

    /// @dev transfer ETH to another account
    function _transferEth(address to, uint128 amount) internal returns (bool sent) {
        sent = _transferEth(to, amount, 0);
    }

    /// @dev transfer ETH to another account
    function _transferEth(address to, uint128 amount, uint256 fallbackId) internal returns (bool sent) {
        (sent, ) = to.call{value: amount}("");
         if (!sent && fallbackId != 0) {
            // fee transfer failed, so add it to stake instead
            _regs[fallbackId].stake += amount;
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