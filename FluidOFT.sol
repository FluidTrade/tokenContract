// SPDX-License-Identifier: MIT

pragma solidity 0.8.21;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IOFT} from "@layerzerolabs/solidity-examples/contracts/token/oft/v1/interfaces/IOFT.sol";
import {OFTCore} from "@layerzerolabs/solidity-examples/contracts/token/oft/v1/OFTCore.sol";

library SafeERC20 {
    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferHelper: INTERNAL TRANSFER_FAILED"
        );
    }
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );
}

contract Fluid is Ownable, ERC20, OFTCore, IOFT {
    uint256 private constant MAX_SUPPLY = 10000000 * (10**18);

    uint256 public maxTransactionAmount = 200_000 * 1e18; //2%
    uint256 public maxWallet = 200_000 * 1e18; //2%
    uint256 public swapTokensAtAmount = (MAX_SUPPLY * 2) / 10000; //0.02%

    address public revWallet;
    address public treasuryWallet;
    address public teamWallet;
    address private WETH;

    uint8 public buyTotalFees = 50;
    uint8 public sellTotalFees = 50;

    uint8 public revFee = 40;
    uint8 public treasuryFee = 20;
    uint8 public teamFee = 40;

    bool private swapping;
    bool public limitsInEffect = true;
    bool private launched;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _isExcludedFromFees;
    mapping(address => bool) private _isExcludedMaxTransactionAmount;
    mapping(address => bool) private automatedMarketMakerPairs;

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 teamETH,
        uint256 revETH,
        uint256 TreasuryETH
    );

    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;

    constructor(
        address _lzEndpoint,
        address _WETHAddress,
        address _revWallet,
        address _treasuryWallet,
        address _teamWallet,
        address _uniswapRouter
    ) ERC20(unicode"Fluid", unicode"FLUID") OFTCore(_lzEndpoint) {
        uniswapV2Router = IUniswapV2Router02(_uniswapRouter);
        WETH = _WETHAddress;
        revWallet = _revWallet;
        treasuryWallet = _treasuryWallet;
        teamWallet = _teamWallet;

        setExcludedFromFees(owner(), true);
        setExcludedFromFees(address(this), true);
        setExcludedFromFees(address(0xdead), true);
        setExcludedFromFees(teamWallet, true);
        setExcludedFromFees(revWallet, true);
        setExcludedFromFees(treasuryWallet, true);

        setExcludedFromMaxTransaction(owner(), true);
        setExcludedFromMaxTransaction(address(uniswapV2Router), true);
        setExcludedFromMaxTransaction(address(this), true);
        setExcludedFromMaxTransaction(address(0xdead), true);
        setExcludedFromMaxTransaction(address(uniswapV2Pair), true);
        setExcludedFromMaxTransaction(teamWallet, true);
        setExcludedFromMaxTransaction(revWallet, true);
        setExcludedFromMaxTransaction(treasuryWallet, true);
    }

    receive() external payable {}

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }

    function _mint(address account, uint256 value) internal virtual override {
        require(totalSupply() + value <= MAX_SUPPLY, "ERC20: cap exceeded");
        super._mint(account, value);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        if (
            !launched &&
            (from != owner() && from != address(this) && to != owner())
        ) {
            revert("Trading not enabled");
        }

        if (limitsInEffect) {
            if (
                from != owner() &&
                to != owner() &&
                to != address(0) &&
                to != address(0xdead) &&
                !swapping
            ) {
                if (
                    automatedMarketMakerPairs[from] &&
                    !_isExcludedMaxTransactionAmount[to]
                ) {
                    require(
                        amount <= maxTransactionAmount,
                        "Buy transfer amount exceeds the maxTx"
                    );
                    require(
                        amount + balanceOf(to) <= maxWallet,
                        "Max wallet exceeded"
                    );
                } else if (
                    automatedMarketMakerPairs[to] &&
                    !_isExcludedMaxTransactionAmount[from]
                ) {
                    require(
                        amount <= maxTransactionAmount,
                        "Sell transfer amount exceeds the maxTx"
                    );
                } else if (!_isExcludedMaxTransactionAmount[to]) {
                    require(
                        amount + balanceOf(to) <= maxWallet,
                        "Max wallet exceeded"
                    );
                }
            }
        }

        bool canSwap = balanceOf(address(this)) >= swapTokensAtAmount;

        if (
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            !_isExcludedFromFees[from] &&
            !_isExcludedFromFees[to]
        ) {
            swapping = true;
            swapBack();
            swapping = false;
        }

        bool takeFee = !swapping;

        if (_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        uint256 senderBalance = _balances[from];
        require(
            senderBalance >= amount,
            "ERC20: transfer amount exceeds balance"
        );

        uint256 fees = 0;
        if (takeFee) {
            if (automatedMarketMakerPairs[to] && sellTotalFees > 0) {
                fees = (amount * sellTotalFees) / 1000;
            } else if (automatedMarketMakerPairs[from] && buyTotalFees > 0) {
                fees = (amount * buyTotalFees) / 1000;
            }

            if (fees > 0) {
                unchecked {
                    amount = amount - fees;
                    _balances[from] -= fees;
                    _balances[address(this)] += fees;
                }
                emit Transfer(from, address(this), fees);
            }
        }
        unchecked {
            _balances[from] -= amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function removeLimits() external onlyOwner {
        limitsInEffect = false;
    }

    function setDistributionFees(
        uint8 _RevFee,
        uint8 _TreasuryFee,
        uint8 _teamFee
    ) external onlyOwner {
        revFee = _RevFee;
        treasuryFee = _TreasuryFee;
        teamFee = _teamFee;
        require(
            (revFee + treasuryFee + teamFee) == 100,
            "Distribution must to be equal to 100%"
        );
    }

    function setFees(uint8 _buyTotalFees, uint8 _sellTotalFees)
        external
        onlyOwner
    {
        require(
            _buyTotalFees <= 50,
            "Buy fees must be less than or equal to 5%"
        );
        require(
            _sellTotalFees <= 50,
            "Sell fees must be less than or equal to 5%"
        );
        buyTotalFees = _buyTotalFees;
        sellTotalFees = _sellTotalFees;
    }

    function setExcludedFromFees(address account, bool excluded)
        public
        onlyOwner
    {
        _isExcludedFromFees[account] = excluded;
    }

    function setExcludedFromMaxTransaction(address account, bool excluded)
        public
        onlyOwner
    {
        _isExcludedMaxTransactionAmount[account] = excluded;
    }

    function bulkSendTokens(
        address[] memory addresses,
        uint256[] memory amounts
    ) external onlyOwner {
        require(!launched, "Already launched");
        for (uint256 i = 0; i < addresses.length; i++) {
            require(
                _balances[msg.sender] >= amounts[i],
                "ERC20: transfer amount exceeds balance"
            );
            _balances[addresses[i]] += amounts[i];
            _balances[msg.sender] -= amounts[i];
            emit Transfer(msg.sender, addresses[i], amounts[i]);
        }
    }

    function createThePool() external payable onlyOwner {
        require(!launched, "Already launched");

        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(
            address(this),
            WETH
        );

        _approve(address(this), address(uniswapV2Pair), type(uint256).max);
        _approve(address(this), address(uniswapV2Router), type(uint256).max);

        IERC20(uniswapV2Pair).approve(
            address(uniswapV2Router),
            type(uint256).max
        );

        automatedMarketMakerPairs[uniswapV2Pair] = true;

        setExcludedFromMaxTransaction(address(uniswapV2Pair), true);

        launched = true;
    }

    function setAutomatedMarketMakerPair(address pair, bool value)
        external
        onlyOwner
    {
        require(pair != uniswapV2Pair, "The pair cannot be removed");
        automatedMarketMakerPairs[pair] = value;
    }

    function setSwapAtAmount(uint256 newSwapAmount) external onlyOwner {
        require(
            newSwapAmount >= (totalSupply() * 1) / 100000,
            "Swap amount cannot be lower than 0.001% of the supply"
        );
        require(
            newSwapAmount <= (totalSupply() * 5) / 1000,
            "Swap amount cannot be higher than 0.5% of the supply"
        );
        swapTokensAtAmount = newSwapAmount;
    }

    function setMaxTxnAmount(uint256 newMaxTx) external onlyOwner {
        require(
            newMaxTx >= ((totalSupply() * 1) / 1000) / 1e18,
            "Cannot set max transaction lower than 0.1%"
        );
        maxTransactionAmount = newMaxTx * (10**18);
    }

    function setMaxWalletAmount(uint256 newMaxWallet) external onlyOwner {
        require(
            newMaxWallet >= ((totalSupply() * 1) / 1000) / 1e18,
            "Cannot set max wallet lower than 0.1%"
        );
        maxWallet = newMaxWallet * (10**18);
    }

    function updateRevWallet(address newAddress) external onlyOwner {
        require(newAddress != address(0), "Address cannot be zero");
        revWallet = newAddress;
    }

    function updateTreasuryWallet(address newAddress) external onlyOwner {
        require(newAddress != address(0), "Address cannot be zero");
        treasuryWallet = newAddress;
    }

    function updateTeamWallet(address newAddress) external onlyOwner {
        require(newAddress != address(0), "Address cannot be zero");
        teamWallet = newAddress;
    }

    function excludedFromFee(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawStuckToken(address tokenAddress, address to)
        external
        onlyOwner
    {
        uint256 _contractBalance = IERC20(tokenAddress).balanceOf(
            address(this)
        );
        SafeERC20.safeTransfer(tokenAddress, to, _contractBalance); // Use safeTransfer
    }

    function withdrawStuckETH(address addr) external onlyOwner {
        require(addr != address(0), "Invalid address");

        (bool success, ) = addr.call{value: address(this).balance}("");
        require(success, "Withdrawal failed");
    }

    function swapBack() private {
        uint256 swapThreshold = swapTokensAtAmount;
        bool success;

        if (balanceOf(address(this)) > swapTokensAtAmount * 20) {
            swapThreshold = swapTokensAtAmount * 20;
        }

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapThreshold,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            uint256 ethForRev = (ethBalance * revFee) / 100;
            uint256 ethForTeam = (ethBalance * teamFee) / 100;
            uint256 ethForTreasury = ethBalance - ethForRev - ethForTeam;

            (success, ) = address(teamWallet).call{value: ethForTeam}("");
            (success, ) = address(treasuryWallet).call{value: ethForTreasury}(
                ""
            );
            (success, ) = address(revWallet).call{value: ethForRev}("");

            emit SwapAndLiquify(
                swapThreshold,
                ethForTeam,
                ethForRev,
                ethForTreasury
            );
        }
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(OFTCore, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IOFT).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function token() public view virtual override returns (address) {
        return address(this);
    }

    function circulatingSupply()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return totalSupply();
    }

    function _debitFrom(
        address _from,
        uint16,
        bytes memory,
        uint256 _amount
    ) internal virtual override returns (uint256) {
        address spender = _msgSender();
        if (_from != spender) _spendAllowance(_from, spender, _amount);
        _burn(_from, _amount);
        return _amount;
    }

    function _creditTo(
        uint16,
        address _toAddress,
        uint256 _amount
    ) internal virtual override returns (uint256) {
        _mint(_toAddress, _amount);
        return _amount;
    }
}
