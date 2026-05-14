# Tickets de entrada — ERC-721 + PaymentGateway

Contratos:

- `src/PaymentGateway.sol` — Copia textual del de clase-2.
- `src/EventTicketNFT.sol` — ERC-721 de entradas. Supply ilimitado, transferible. Dos roles:
  - **owner** (vos): controla metadata (`setBaseURI`) y designa al minter (`setMinter`).
  - **minter** (el gateway): es el único que puede acuñar entradas.
- `src/PaymentGatewayWithTicket.sol` — Hereda `PaymentGateway`. `_onPaid` llama `ticket.mintTicket(payer, action)`.

## Setup

```bash
cd clase-extra-tickets
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-commit --no-git
forge build
forge test
# 6 tests pasando
```

## Variables de entorno

Reusar `.env` de clase-2 y agregar:

```bash
TICKET_NAME="VibeCheck Entry"
TICKET_SYMBOL="VIBE-TKT"
TICKET_BASE_URI=""   # vacío por ahora; setear después con setBaseURI cuando tengas la metadata en IPFS
```

## Deploy

```bash
source .env

forge script script/DeployTicketAndGateway.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --account dev \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

Output:

```
EventTicketNFT deployed at:            0x...
PaymentGatewayWithTicket deployed at:  0x...
```

El script ya hace `setMinter(gateway)` automáticamente. Tras el deploy:
- Vos seguís siendo owner del NFT → podés cambiar baseURI cuando subas la metadata.
- Solo el gateway puede mintear → para conseguir un ticket hay que pagar.

## Probar el flow

```bash
export TICKET=0x...     # EventTicketNFT
export GATEWAY=0x...    # PaymentGatewayWithTicket

# Approve 50 USDC al gateway
cast send $USDC_SEPOLIA "approve(address,uint256)" $GATEWAY 50000000 \
  --rpc-url $SEPOLIA_RPC_URL --account dev

# Pagar → recibís un NFT automáticamente
cast send $GATEWAY "pay(uint256,bytes32)" 50000000 \
  0x$(echo -n "vibecheck-2026" | xxd -p | head -c 64) \
  --rpc-url $SEPOLIA_RPC_URL --account dev

# Verificar
cast call $TICKET "balanceOf(address)(uint256)" $TREASURY \
  --rpc-url $SEPOLIA_RPC_URL
# 1

cast call $TICKET "ownerOf(uint256)(address)" 1 \
  --rpc-url $SEPOLIA_RPC_URL
# tu address

cast call $TICKET "ticketAction(uint256)(bytes32)" 1 \
  --rpc-url $SEPOLIA_RPC_URL
# 0x76696265636865636b2d32303236...  ("vibecheck-2026")
```

## Agregar metadata (imagen, descripción) después del deploy

1. Subí una imagen a IPFS (Pinata, web3.storage, etc.). Anotá el CID.
2. Por cada token que ya minteaste, subí un JSON:
   ```json
   {
     "name": "VibeCheck Entry #1",
     "description": "Entrada al evento VibeCheck 2026",
     "image": "ipfs://CID-DE-LA-IMAGEN"
   }
   ```
   Los JSON deben llamarse `1`, `2`, `3`... (sin extensión) y estar en una misma carpeta IPFS.
3. Subí la carpeta y obtené el CID de la carpeta.
4. Setealo en el contrato:
   ```bash
   cast send $TICKET "setBaseURI(string)" "ipfs://CID-DE-LA-CARPETA/" \
     --rpc-url $SEPOLIA_RPC_URL --account dev
   ```
5. OpenSea / wallets resolverán `tokenURI(1)` → `ipfs://CID/1` → tu JSON → tu imagen.
