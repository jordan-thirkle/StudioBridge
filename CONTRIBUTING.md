# Contributing

Studio Bridge is a community tool for Rojo developers.

## Reporting Issues

Open a GitHub issue with:
- What you were doing
- What you expected to happen
- What actually happened (include error text)

## Submitting Changes

1. Fork the repo
2. Create a feature branch
3. Make your changes
4. Test with `.\install.ps1` on a clean machine
5. Submit a pull request

## Code Style

- PowerShell 5.1 compatible (no PS7-only features)
- Tab indentation, 120 column width
- All errors handled gracefully (no silent crashes)
- UI strings use ASCII only for PS5.1 compatibility
