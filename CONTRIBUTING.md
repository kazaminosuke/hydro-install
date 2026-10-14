# Contributing to Hydrodactyl Installer

Thank you for your interest in contributing! This document outlines the guidelines for contributing to this project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Branch Naming Convention](#branch-naming-convention)
- [Commit Convention](#commit-convention)
- [Pull Request Process](#pull-request-process)
- [Code Style](#code-style)
- [Testing](#testing)

## Code of Conduct

This project adheres to the [Contributor Covenant](CODE_OF_CONDUCT.md). By participating, you agree to uphold this code.

## Getting Started

1. Fork the repository
2. Create a branch following the naming convention below
3. Make your changes
4. Submit a pull request

## Development Setup

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/hydro-install.git
cd hydro-install

# The installer scripts are written in pure Bash
# No build tools or package managers are required
```

To test the installer locally, you can run specific scripts with a dry-run approach:

```bash
# Check syntax of all scripts
for f in install.sh lib/*.sh installers/*.sh ui/*.sh; do
    bash -n "$f" && echo "✓ $f" || echo "✗ $f"
done
```

## Branch Naming Convention

Branch names must follow one of these patterns:

| Prefix | Purpose |
| -------- | --------- |
| `feature/*` | New features |
| `fix/*` | Bug fixes |
| `docs/*` | Documentation changes |
| `chore/*` | Maintenance tasks |
| `refactor/*` | Code refactoring |
| `perf/*` | Performance improvements |
| `test/*` | Test additions or changes |
| `ci/*` | CI/CD changes |
| `build/*` | Build system changes |
| `revert/*` | Reverting changes |

Examples: `feature/ssl-support`, `fix/database-timeout`, `docs/update-readme`

## Commit Convention

This project uses [Conventional Commits](https://www.conventionalcommits.org/).

```text
<type>: <description>

[optional body]

[optional footer]
```

Allowed types: `feat`, `fix`, `docs`, `chore`, `refactor`, `perf`, `test`, `ci`, `build`, `revert`

Examples:

```text
feat: add automatic SSL renewal hook for Elytra
fix: resolve FQDN validation on IPv6-only servers
docs: update installation requirements for Ubuntu 24.04
chore: bump default PHP version to 8.3
```

## Pull Request Process

1. Ensure your branch name follows the naming convention
2. Ensure your commits follow the Conventional Commits specification
3. Update documentation if your changes affect the installation process or requirements
4. Verify your changes with `bash -n` syntax checking
5. Submit the PR with a clear description of the changes

## Code Style

- Use 4-space indentation
- Use `[[ ]]` for conditionals (Bash 4+)
- Quote all variable expansions
- Prefer `local` variables in functions
- Use `lowercase_with_underscores` for variable names
- Use `UPPERCASE_WITH_UNDERSCORES` for exported environment variables
- Add `set -e` or handle errors explicitly
- Keep functions focused and well-documented

## Testing

Currently, this project uses ShellCheck for static analysis and `bash -n` for syntax validation:

```bash
# Install ShellCheck
sudo apt install shellcheck  # Debian/Ubuntu
sudo dnf install shellcheck  # Fedora/RHEL

# Run linting
shellcheck install.sh lib/*.sh installers/*.sh ui/*.sh

# Check syntax
for f in install.sh lib/*.sh installers/*.sh ui/*.sh; do
    bash -n "$f"
done
```

If contributing logic changes, ensure the installer still completes a full installation flow on a supported OS.
