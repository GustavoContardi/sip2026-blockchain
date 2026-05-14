// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Pausable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title EventTicketNFT
 * @notice ERC-721 de entradas. Cada token = una entrada al evento.
 *         Supply ilimitado. Transferibles (default ERC-721).
 *         Roles:
 *           - owner  (Ownable): gestiona metadata (setBaseURI, setMinter, pause).
 *           - minter (address): puede acuñar (será el PaymentGateway).
 *         Pausable: el owner puede frenar minting y transferencias en emergencias.
 */
contract EventTicketNFT is ERC721, ERC721Pausable, Ownable {
    using Strings for uint256;

    uint256 private _nextId;
    string private _baseTokenURI;
    address public minter;

    mapping(uint256 => bytes32) public ticketAction;

    event TicketMinted(address indexed to, uint256 indexed tokenId, bytes32 indexed action);
    event MinterSet(address indexed previousMinter, address indexed newMinter);

    error NotMinter();
    error ZeroAddress();

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    constructor(string memory name_, string memory symbol_, address owner_, string memory baseURI_)
        ERC721(name_, symbol_)
        Ownable(owner_)
    {
        _baseTokenURI = baseURI_;
    }

    /// @notice Designar quién puede mintear (típicamente el PaymentGateway).
    function setMinter(address newMinter) external onlyOwner {
        if (newMinter == address(0)) revert ZeroAddress();
        emit MinterSet(minter, newMinter);
        minter = newMinter;
    }

    /// @notice Mintea una entrada. Llamado por el PaymentGateway en cada `pay()`.
    function mintTicket(address to, bytes32 action) external onlyMinter whenNotPaused returns (uint256 tokenId) {
        tokenId = ++_nextId;
        ticketAction[tokenId] = action;
        _mint(to, tokenId);
        emit TicketMinted(to, tokenId, action);
    }

    /// @notice Pausa minting y transferencias. Solo owner.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Reanuda operaciones. Solo owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Cuántas entradas se emitieron hasta ahora.
    function totalMinted() external view returns (uint256) {
        return _nextId;
    }

    /// @notice Cambiar el base URI (solo owner).
    function setBaseURI(string calldata newBase) external onlyOwner {
        _baseTokenURI = newBase;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /// @dev Resolver la herencia múltiple ERC721 + ERC721Pausable.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Pausable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }
}
