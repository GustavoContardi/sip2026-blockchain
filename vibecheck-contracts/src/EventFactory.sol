// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EventNFT} from "./EventNFT.sol";

/**
 * @title EventFactory
 * @notice Factory que deploya un EventNFT por evento.
 *
 *         Flujo:
 *           1. Admin de la plataforma deploya el factory.
 *           2. Admin deploya OfferingNFT y NFTMarketplace apuntando a este factory.
 *           3. Admin llama `setOffering(...)` y `setMarketplace(...)` (one-shot).
 *           4. Admin otorga ORGANIZER_ROLE a las productoras validadas off-chain (KYC).
 *           5. Cada productora llama `launchEvent(...)` y recibe la address de su EventNFT.
 *           6. El factory otorga automáticamente MINTER_ROLE al offering y MARKET_ROLE
 *              al marketplace sobre el nuevo EventNFT.
 */
contract EventFactory is AccessControl {
    bytes32 public constant ORGANIZER_ROLE = keccak256("ORGANIZER_ROLE");

    address public immutable usdc;
    address public immutable vbk;
    address public immutable router;        // Uniswap V2 Router (para pricing de VBK)
    address public immutable treasury;      // recibe fees de plataforma

    address public offering;
    address public marketplace;

    /// @notice Registro de todos los EventNFT lanzados.
    address[] public events;
    /// @notice Lookup rápido para validar que una address es un evento conocido.
    mapping(address => bool) public isEvent;

    event OfferingSet(address indexed offering);
    event MarketplaceSet(address indexed marketplace);
    event EventLaunched(
        address indexed organizer,
        address indexed eventNFT,
        string name,
        uint256 eventDate
    );

    error ZeroAddress();
    error AlreadySet();
    error InfraNotReady();

    constructor(
        address admin_,
        address usdc_,
        address vbk_,
        address router_,
        address treasury_
    ) {
        if (admin_ == address(0) || usdc_ == address(0) || vbk_ == address(0)
            || router_ == address(0) || treasury_ == address(0)) revert ZeroAddress();

        usdc = usdc_;
        vbk = vbk_;
        router = router_;
        treasury = treasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    // -----------------------------------------------------------------
    // Bootstrap (one-shot por la chicken-and-egg con offering/marketplace)
    // -----------------------------------------------------------------

    function setOffering(address offering_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (offering_ == address(0)) revert ZeroAddress();
        if (offering != address(0)) revert AlreadySet();
        offering = offering_;
        emit OfferingSet(offering_);
    }

    function setMarketplace(address marketplace_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (marketplace_ == address(0)) revert ZeroAddress();
        if (marketplace != address(0)) revert AlreadySet();
        marketplace = marketplace_;
        emit MarketplaceSet(marketplace_);
    }

    /// @notice Atajo para que el admin habilite productoras (post-KYC off-chain).
    function grantOrganizer(address productora) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(ORGANIZER_ROLE, productora);
    }

    function revokeOrganizer(address productora) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(ORGANIZER_ROLE, productora);
    }

    // -----------------------------------------------------------------
    // Lanzamiento de eventos
    // -----------------------------------------------------------------

    /// @notice Parámetros del evento, agrupados para evitar stack too deep en `launchEvent`.
    ///         El tope de reventa se define por tier, no a nivel de evento.
    struct EventParams {
        string name;               // Nombre del ERC-721 (ej. "Recital Cosquin 2026")
        string symbol;             // Símbolo del ERC-721 (ej. "CSQ26")
        uint256 eventDate;         // Timestamp UNIX del evento
        address venueSigner;       // Address que firma QRs en puerta
        string baseURI;            // Prefijo IPFS para metadata
    }

    /**
     * @notice Lanza un nuevo evento. Solo productoras con ORGANIZER_ROLE.
     * @param p     Parámetros del evento (ver EventParams).
     * @param tiers Array de tiers (cada uno con nombre, precio USDC, supply y tope de reventa).
     */
    function launchEvent(EventParams calldata p, EventNFT.Tier[] calldata tiers)
        external
        onlyRole(ORGANIZER_ROLE)
        returns (address)
    {
        if (offering == address(0) || marketplace == address(0)) revert InfraNotReady();

        EventNFT.InitParams memory init = EventNFT.InitParams({
            name: p.name,
            symbol: p.symbol,
            organizer: msg.sender,
            eventDate: p.eventDate,
            venueSigner: p.venueSigner,
            baseURI: p.baseURI
        });

        EventNFT nft = new EventNFT(init, tiers);

        // El factory tiene DEFAULT_ADMIN_ROLE sobre el EventNFT (otorgado en el constructor del NFT).
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
