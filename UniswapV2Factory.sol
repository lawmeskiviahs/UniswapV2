// SPDX-License-Identifier: MITclamsetup
pragma solidity ^0.8.7;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';


contract UniswapV2Factory {
    address public feeTo;           // address to which the fee would be sent
    address public feeToSetter;     // address which would set the feeTo address

    mapping(address => mapping(address => address)) public getPair;     // mapping of pair contracts and their token pairs
    address[] public allPairs;                                          // list of all pairs

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);  // event emitted at the time of new pair creation

    constructor(address _feeToSetter) { // _feeToSetter is provided in input at the time of deployment
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;     // means the total number of pairs created
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);   // sorting
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient

        // creating the contract address with seeds kind of like findProgramAddress
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        pair = address(uint160(uint(keccak256(abi.encodePacked(
                hex'ff',
                address(this),
                keccak256(abi.encodePacked(token0, token1)),
                hex'a8f4dc674bff285be4a3ac3c06ecf569d2236da40664732af5cf9fc3631daac9' // init code hash
            )))));
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
