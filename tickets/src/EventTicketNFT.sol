// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title EventTicketNFT
 * @notice ERC-721 de entradas. Cada token = una entrada al evento.
 *         Supply ilimitado. Transferibles (default ERC-721).
 *         Dos roles separados:
 *           - owner  (Ownable): gestiona metadata (setBaseURI, setMinter).
 *           - minter (address): puede acuñar (será el PaymentGateway).
 */
contract EventTicketNFT is ERC721, Ownable {
    using Strings for uint256;

    uint256 private _nextId;
    string private _baseTokenURI;
    address public minter;

    mapping(uint256 => bytes32) public ticketAction;

    event TicketMinted(address indexed to, uint256 indexed tokenId, bytes32 indexed action);
    event MinterSet(address indexed previousMinter, address indexed newMinter);

    error NotMinter();

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
        emit MinterSet(minter, newMinter);
        minter = newMinter;
    }

    /// @notice Mintea una entrada. Llamado por el PaymentGateway en cada `pay()`.
    function mintTicket(address to, bytes32 action) external onlyMinter returns (uint256 tokenId) {
        tokenId = ++_nextId;
        ticketAction[tokenId] = action;
        _mint(to, tokenId);
        emit TicketMinted(to, tokenId, action);
    }

    /// @notice Cuántas entradas se emitieron hasta ahora.
    function totalMinted() external view returns (uint256) {
        return _nextId;
    }

    /// @notice Cambiar el base URI (solo owner). Se puede llamar después del deploy.
    function setBaseURI(string calldata newBase) external onlyOwner {
        _baseTokenURI = newBase;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
}
