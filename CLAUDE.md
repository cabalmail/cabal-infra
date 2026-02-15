# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build/Lint/Test Commands
- React app: `cd react/admin && npm run start` (development)
- React app build: `cd react/admin && npm run build`
- React app tests: `cd react/admin && npm run test`
- Run single test: `cd react/admin && npm run test -- -t "test name"`
- Python linting: `pylint lambda/api/python/**/*.py`
- Lambda function local testing: `cd lambda/api/[function_dir] && python -m function`

## Code Style Guidelines
- **JavaScript/React**:
  - Class-based React components with explicit state management
  - Import order: third-party libs, main components, utilities, styles
  - Error handling with try/catch blocks and explicit error messaging
  - Use camelCase for variables/functions, PascalCase for components
  - JSDoc comments for function documentation
  
- **Python**:
  - Function docstrings using triple quotes
  - Snake_case for variables and functions
  - Disable specific pylint warnings with inline comments when necessary
  - Import standard libs first, then custom modules
  
- **Terraform**:
  - Follow HashiCorp style conventions
  - Document modules and variables thoroughly
  - Group related resources in modules
  - Use locals for repeated values or complex expressions

## Repository Structure
- `react/admin`: React frontend application
- `lambda/api`: AWS Lambda functions (Python, Node.js)
- `terraform`: Infrastructure as code
- `chef`: Server configuration management
- `docker`: Docker configuration files