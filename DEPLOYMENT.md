# Deployment

The deploy script is self-contained: it deploys the protocol, two demo reserves
(WETH + USDC as mintable mocks), and Chainlink-style mock aggregators, then wires
and configures them. Nothing external is required beyond a funded key.

## Local (anvil)

```bash
anvil &
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 \
  --broadcast --private-key <ANVIL_KEY>
```

## Sepolia, with source verification

```bash
cp .env.example .env      # then fill in your values
source .env

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --broadcast \
  --private-key $PRIVATE_KEY \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
```

The run prints every deployed address. `--verify` uploads and verifies source on
Etherscan automatically; once it completes, each contract is readable and
interactive from its Etherscan page.

## After deploying

Record the addresses here so the README can link to verified source:

| Contract | Sepolia address |
|---|---|
| LendingPool | `0x…` |
| PoolConfigurator | `0x…` |
| ChainlinkPriceOracle | `0x…` |
| DefaultInterestRateStrategy | `0x…` |
| WETH (demo) | `0x…` |
| USDC (demo) | `0x…` |

## Notes

- The deployer key is read from the environment and never written to disk. Use a
  throwaway key for testnets.
- On a production network you would replace the `MockV3Aggregator`s with real
  Chainlink feed addresses and drop the demo `MockERC20`s. The oracle adapter,
  rate strategy, and pool are production-shaped as written.
