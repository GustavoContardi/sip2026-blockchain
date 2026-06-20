// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Subconjunto de EventFactory que este contrato necesita.
interface IEventFactoryView {
    function isEvent(address nft) external view returns (bool);
}

/// @notice Subconjunto del router de Uniswap V2 que este contrato necesita.
///         Mismo patrón que OfferingNFT/NFTMarketplace: solo cotiza, no swapea.
interface IUniswapV2RouterView {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

/**
 * @title RewardsVault
 * @notice Acredita una recompensa fija en VBK a cada fan que hace check-in
 *         (redeem) en un evento. El monto está fijado en USDC (0.10 USDC) y
 *         se convierte a VBK al momento del redeem usando el mismo pool de
 *         cotización que ya usan OfferingNFT y NFTMarketplace.
 *
 *         El VBK pagado sale de una wallet `treasury` externa, ya fondeada,
 *         que le dio `approve` a este contrato. RewardsVault nunca custodia
 *         el VBK fuera del propio `transferFrom` de cada pago: no hay
 *         depósito ni balance propio que drenar más allá del allowance
 *         vigente en cada momento.
 *
 *         Solo EventNFTs reconocidos por `factory.isEvent()` pueden disparar
 *         un pago, vía `notifyRedeem`. Esto evita que un contrato arbitrario
 *         simule un check-in falso para cobrar recompensas.
 *
 *         Si el treasury no tiene fondos o allowance suficiente al momento
 *         del pago, `notifyRedeem` NO revierte: emite `RewardPaymentFailed`
 *         y retorna. El check-in en EventNFT ya está confirmado en ese punto
 *         (EventNFT llama a este contrato con try/catch) y no debe bloquearse
 *         por un problema de fondos del treasury.
 */
contract RewardsVault is Ownable, Pausable {
    /// @notice Recompensa fija, denominada en USDC (6 decimales), por cada redeem.
    uint256 public rewardUSDC = 0.10e6;

    IEventFactoryView      public factory;
    IUniswapV2RouterView   public router;
    address                public usdc;
    address                public vbk;
    address                public treasury;

    /// @notice Por evento + tokenId, si ya se pagó la recompensa.
    ///         Evita doble pago si notifyRedeem se llamara más de una vez
    ///         para el mismo ticket (defensa en profundidad: EventNFT ya
    ///         garantiza que redeem() solo ocurre una vez por tokenId, pero
    ///         este contrato no depende únicamente de esa garantía externa).
    mapping(address => mapping(uint256 => bool)) public rewardPaid;

    event RewardPaid(address indexed eventNFT, uint256 indexed tokenId, address indexed fan, uint256 vbkAmount);
    event RewardPaymentFailed(address indexed eventNFT, uint256 indexed tokenId, address indexed fan, string reason);
    event RewardUSDCUpdated(uint256 previous, uint256 next);
    event TreasuryUpdated(address indexed previous, address indexed next);
    event RouterUpdated(address indexed previous, address indexed next);
    event FactoryUpdated(address indexed previous, address indexed next);

    error UnknownEvent();
    error ZeroAddress();
    error AlreadyPaid();

    constructor(address admin, address factory_, address router_, address usdc_, address vbk_, address treasury_)
        Ownable(admin)
    {
        // admin == address(0) ya revierte en Ownable(admin) arriba, con
        // Ownable.OwnableInvalidOwner — antes de que este cuerpo se ejecute.
        if (
            factory_ == address(0) || router_ == address(0) ||
            usdc_ == address(0) || vbk_ == address(0) || treasury_ == address(0)
        ) revert ZeroAddress();

        factory  = IEventFactoryView(factory_);
        router   = IUniswapV2RouterView(router_);
        usdc     = usdc_;
        vbk      = vbk_;
        treasury = treasury_;
    }

    // -----------------------------------------------------------------
    // Notificación de redeem (llamado por EventNFT)
    // -----------------------------------------------------------------

    /**
     * @notice Acredita la recompensa en VBK al fan que acaba de hacer check-in.
     * @dev Solo callable por un EventNFT reconocido por la factory
     *      (`factory.isEvent(msg.sender) == true`). EventNFT llama esto
     *      dentro de un try/catch: cualquier revert acá NO bloquea el
     *      check-in del fan, pero sí evita que se pague la recompensa.
     *      Por eso los casos de "fondos insuficientes" se manejan con un
     *      evento, no con un revert (ver `_payReward`).
     */
    function notifyRedeem(address fan, uint256 tokenId) external whenNotPaused {
        if (!factory.isEvent(msg.sender)) revert UnknownEvent();
        if (fan == address(0)) revert ZeroAddress();
        if (rewardPaid[msg.sender][tokenId]) revert AlreadyPaid();

        _payReward(msg.sender, tokenId, fan);
    }

    function _payReward(address eventNFT, uint256 tokenId, address fan) internal {
        address[] memory path = new address[](2);
        path[0] = usdc;
        path[1] = vbk;

        // Cotización vía pool, igual patrón que OfferingNFT/NFTMarketplace.
        // getAmountsOut puede revertir si el pool no tiene liquidez; lo
        // capturamos también, por eso esta función nunca propaga el revert
        // hacia notifyRedeem.
        try router.getAmountsOut(rewardUSDC, path) returns (uint256[] memory amounts) {
            uint256 vbkAmount = amounts[amounts.length - 1];

            try IERC20(vbk).transferFrom(treasury, fan, vbkAmount) returns (bool ok) {
                if (!ok) {
                    emit RewardPaymentFailed(eventNFT, tokenId, fan, "transferFrom returned false");
                    return;
                }
                rewardPaid[eventNFT][tokenId] = true;
                emit RewardPaid(eventNFT, tokenId, fan, vbkAmount);
            } catch Error(string memory reason) {
                emit RewardPaymentFailed(eventNFT, tokenId, fan, reason);
            } catch {
                emit RewardPaymentFailed(eventNFT, tokenId, fan, "transferFrom reverted");
            }
        } catch {
            emit RewardPaymentFailed(eventNFT, tokenId, fan, "router quote failed");
        }
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    function setRewardUSDC(uint256 newRewardUSDC) external onlyOwner {
        emit RewardUSDCUpdated(rewardUSDC, newRewardUSDC);
        rewardUSDC = newRewardUSDC;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        emit RouterUpdated(address(router), newRouter);
        router = IUniswapV2RouterView(newRouter);
    }

    function setFactory(address newFactory) external onlyOwner {
        if (newFactory == address(0)) revert ZeroAddress();
        emit FactoryUpdated(address(factory), newFactory);
        factory = IEventFactoryView(newFactory);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -----------------------------------------------------------------
    // Lectura
    // -----------------------------------------------------------------

    /// @notice Cuánto VBK se pagaría ahora mismo por una recompensa, según el pool.
    function quoteReward() external view returns (uint256 vbkAmount) {
        address[] memory path = new address[](2);
        path[0] = usdc;
        path[1] = vbk;
        uint256[] memory amounts = router.getAmountsOut(rewardUSDC, path);
        return amounts[amounts.length - 1];
    }
}
