// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is UniswapV2ERC20 {

    using SafeMath  for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10**3;

    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)'))); // used to send token to two token accounts ?

    address public factory;     // address of the factory contract
    address public token0;      // address of token0 contract
    address public token1;      // address of token1 contract

    uint112 private reserve0;           // amount of token0 in pool, accessible via getReserves
    uint112 private reserve1;           // amount of token1 in pool, accessible via getReserves

    uint32  private blockTimestampLast; // The timestamp for the last block in which an exchange happened, accessible via getReserves

    uint public price0CumulativeLast;       // cost of token0 in terms of token1
    uint public price1CumulativeLast;       // cost of token1 in terms of token0

    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint private unlocked = 1;      // used to prevent re-entrancy attacks
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // this function provides the caller with the current status of the exchange
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) { 
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // transfers 'value' amount of 'token' to 'to'
    function _safeTransfer(address token, address to, uint value) private {
           
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));        // manually create the call function using ABI functions
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');       // making sure the transfer was done

    }

    // while adding/removing liquidity
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    
    // while swapping tokens
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );

    // this event is called each time tokens are withdrawn or deposited regardless of the reason
    event Sync(uint112 reserve0, uint112 reserve1);

    // because the pair contract will be called by the factory first, it records the msg.sender as factory 
    // is is done so as to keep record of factory at the time of deployment
    constructor() {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    // sets the pair of tokens for the pool
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {

        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, 'UniswapV2: OVERFLOW'); // preventing overflow of tokens inside the storage, limit of tokens currently is 5.1x10^15 oh each token as uint 112

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;

        emit Sync(reserve0, reserve1);

    }

    // called to check if the fee is on
    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {

        address feeTo = IUniswapV2Factory(factory).feeTo();     // loading address feeTo from the factory contract
        feeOn = feeTo != address(0);        // bool value for if fee is On or OFF
        uint _kLast = kLast; // gas savings

        if (feeOn) 

            if (_kLast != 0) {

                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);

                if (rootK > rootKLast) {

                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);

                }

        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    // this function is called by the periphery contract when a liquidity provider adds liquidity to a pool
    function mint(address to) external lock returns (uint liquidity) {

        // solidity way to read results of a multi-return type function
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings


        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        uint amount0 = balance0.sub(_reserve0); // amount of token0 added to the pool
        uint amount1 = balance1.sub(_reserve1); // amount of token1 added to the pool

        // calculating protocol fee
        bool feeOn = _mintFee(_reserve0, _reserve1);

        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee

        if (_totalSupply == 0) { // if this is the first deposit
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens (minimum liquidity is the number of tokens that will always exist so that the pool is never emptied completely)
        } else { // in subsequent adding of liquidity
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED'); // checks if the liquidity provider added zero liquidity (if he put in 0 amount of any of the two tokens)
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1); // update the priceCumulativeLast, reserves and blockTimestampLast
        
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date

        emit Mint(msg.sender, amount0, amount1); // event Mint
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {

        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings

        uint balance0 = IERC20(_token0).balanceOf(address(this));   // balance also denotes the amount of token in the reserves
        uint balance1 = IERC20(_token1).balanceOf(address(this));   // balance also denotes the amount of token in the reserves

        uint liquidity = balanceOf[address(this)];  // amount of liquidity token provided by the owner

        bool feeOn = _mintFee(_reserve0, _reserve1);    // check if fee is on

        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee

        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution

        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED'); // ensuring that liquidity provided by the owner is not zero (assuming there is some liquidity in the pool)
        _burn(address(this), liquidity);

        _safeTransfer(_token0, to, amount0);    // transfer the calculated amount of token0 to the owner
        _safeTransfer(_token1, to, amount1);    // transfer the calculated amount of token0 to the owner

        balance0 = IERC20(_token0).balanceOf(address(this));    // updating balance of token0
        balance1 = IERC20(_token1).balanceOf(address(this));    // updating balance of token1

        _update(balance0, balance1, _reserve0, _reserve1);  // update the priceCumulativeLast, reserves and blockTimestampLast
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);    // event Burn
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT'); // 
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;

        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;

        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens

        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);  // ?

        balance0 = IERC20(_token0).balanceOf(address(this));    // getting current balances. The periphery contracts sends tokens to the pair before calling it for swap. This makes it easy for the contract to check that it is not being cheated 
        balance1 = IERC20(_token1).balanceOf(address(this));    // getting current balances. The periphery contracts sends tokens to the pair before calling it for swap. This makes it easy for the contract to check that it is not being cheated

        }

        // sanity check
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;   // checking if the sums and differences after the swap match
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;   // checking if the sums and differences after the swap match

        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));

        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);  // update the priceCumulativeLast, reserves and blockTimestampLast
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);    // event Swap
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0)); // transfer extra tokens
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1)); // transfer extra tokens
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
