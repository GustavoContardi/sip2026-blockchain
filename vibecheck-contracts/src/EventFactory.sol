// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EventNFT} from "./EventNFT.sol";

/**
 * @title EventFactory
 * @notice Factory que deploya un EventNFT por evento.
 *
 *         Cualquier address puede lanzar eventos. No hay permiso de organizador:
 *         si alguien quiere crear eventos fantasma que pague el gas.
 *         El control de acceso existe a nivel de aplicacion (backend/frontend).
 *
 *         Flujo:
 *           1. Admin deploya el factory.
 *           2. Admin deploya OfferingNFT y NFTMarketplace apuntando a este factory.
 *           3. Admin llama setOffering(...) y setMarketplace(...) (one-shot).
 *           4. Admin opcionalmente llama setRewardsVault(...) para que todo
 *              evento lanzado de aca en mas nazca con recompensas activadas.
 *           5. Cualquier wallet puede llamar launchEvent(...).
 *           6. El factory otorga automaticamente MINTER_ROLE al offering y MARKET_ROLE
 *              al marketplace sobre el nuevo EventNFT, y le pasa el rewardsVault
 *              vigente (si hay uno configurado) para que nazca ya activado.
 */
contract EventFactory {

    address public immutable admin;
    address public immutable usdc;
    address public immutable vbk;
    address public immutable router;        // Uniswap V2 Router (para pricing de VBK)
    address public immutable treasury;      // recibe fees de plataforma

    address public offering;
    address public marketplace;

    /// @notice RewardsVault vigente. Se inyecta en cada EventNFT nuevo al
    ///         momento de lanzarlo. address(0) = recompensas no configuradas
    ///         todavia; los eventos nacen sin ellas (igual que antes).
    ///         Cambiarlo NO afecta eventos ya lanzados — eso se hace, evento
    ///         por evento, con EventNFT.setRewardsVault (el organizador).
    address public rewardsVault;

    /// @notice Registro de todos los EventNFT lanzados.
    address[] public events;
    /// @notice Lookup rapido para validar que una address es un evento conocido.
    mapping(address => bool) public isEvent;

    event OfferingSet(address indexed offering);
    event MarketplaceSet(address indexed marketplace);
    event RewardsVaultSet(address indexed previous, address indexed next);
    event EventLaunched(
        address indexed organizer,
        address indexed eventNFT,
        string name,
        uint256 eventDate
    );

    error ZeroAddress();
    error AlreadySet();
    error InfraNotReady();
    error OnlyAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor(
        address admin_,
        address usdc_,
        address vbk_,
        address router_,
        address treasury_
    ) {
        if (admin_ == address(0) || usdc_ == address(0) || vbk_ == address(0)
            || router_ == address(0) || treasury_ == address(0)) revert ZeroAddress();

        admin     = admin_;
        usdc      = usdc_;
        vbk       = vbk_;
        router    = router_;
        treasury  = treasury_;
    }

    // -----------------------------------------------------------------
    // Bootstrap (one-shot por la chicken-and-egg con offering/marketplace)
    // -----------------------------------------------------------------

    function setOffering(address offering_) external onlyAdmin {
        if (offering_ == address(0)) revert ZeroAddress();
        if (offering != address(0)) revert AlreadySet();
        offering = offering_;
        emit OfferingSet(offering_);
    }

    function setMarketplace(address marketplace_) external onlyAdmin {
        if (marketplace_ == address(0)) revert ZeroAddress();
        if (marketplace != address(0)) revert AlreadySet();
        marketplace = marketplace_;
        emit MarketplaceSet(marketplace_);
    }

    /// @notice Configura (o desactiva con address(0)) el RewardsVault que se
    ///         inyecta a todo EventNFT lanzado de aca en mas. A diferencia de
    ///         setOffering/setMarketplace, esto NO es one-shot: se puede
    ///         cambiar las veces que haga falta (ej. si el vault se migra).
    ///         No afecta eventos ya existentes.
    function setRewardsVault(address rewardsVault_) external onlyAdmin {
        emit RewardsVaultSet(rewardsVault, rewardsVault_);
        rewardsVault = rewardsVault_;
    }

    // -----------------------------------------------------------------
    // Lanzamiento de eventos — abierto a cualquier wallet
    // -----------------------------------------------------------------

    /// @notice Parametros del evento, agrupados para evitar stack too deep en launchEvent.
    struct EventParams {
        string name;               // Nombre del ERC-721 (ej. "Recital Cosquin 2026")
        string symbol;             // Simbolo del ERC-721 (ej. "CSQ26")
        uint256 eventDate;         // Timestamp UNIX del evento
        uint16 maxResalePriceBps;  // Tope de reventa (bps). 10000=100%, 12000=120%
        uint16 royaltyBps;         // Royalty al organizador (bps). Tope: 2000 = 20%
        address venueSigner;       // Address que firma QRs en puerta
        string baseURI;            // Prefijo IPFS para metadata
    }

    /**
     * @notice Lanza un nuevo evento. Abierto a cualquier wallet.
     * @param p     Parametros del evento (ver EventParams).
     * @param tiers Array de tiers (cada uno con nombre, precio USDC y supply).
     */
    function launchEvent(EventParams calldata p, EventNFT.Tier[] calldata tiers)
        external
        returns (address)
    {
        if (offering == address(0) || marketplace == address(0)) revert InfraNotReady();

        EventNFT.InitParams memory init = EventNFT.InitParams({
            name: p.name,
            symbol: p.symbol,
            organizer: msg.sender,
            eventDate: p.eventDate,
            maxResalePriceBps: p.maxResalePriceBps,
            royaltyBps: p.royaltyBps,
            venueSigner: p.venueSigner,
            baseURI: p.baseURI,
            rewardsVault: rewardsVault
        });

        EventNFT nft = new EventNFT(init, tiers);

        nft.grantRole(nft.MINTER_ROLE(), offering);
        nft.grantRole(nft.MARKET_ROLE(), marketplace);

        address nftAddr = address(nft);
        events.push(nftAddr);
        isEvent[nftAddr] = true;

        emit EventLaunched(msg.sender, nftAddr, p.name, p.eventDate);
        return nftAddr;
    }

    // -----------------------------------------------------------------
    // Lectura
    // -----------------------------------------------------------------

    function eventsLength() external view returns (uint256) {
        return events.length;
    }
}
