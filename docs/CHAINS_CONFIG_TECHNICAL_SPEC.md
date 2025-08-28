# Chains Configuration Feature - Technical Specification

## Overview
This document outlines the technical specification for implementing a dashboard chains config input feature that allows users to dynamically add and manage blockchain configurations.

## Current Architecture Analysis

### Configuration System
- **Storage**: YAML-based configuration (`config/chains.yml`)
- **Runtime Cache**: ETS-based ConfigStore for fast access
- **Predefined Chains**: 8 chains currently supported
- **Validation**: Basic validation in `ChainConfig` module
- **No Database**: File-based configuration only

### Key Files
- `/lib/livechain/config/chain_config.ex` - Core configuration logic
- `/lib/livechain_web/dashboard/dashboard.ex` - Dashboard LiveView
- `/config/chains.yml` - Chain definitions

## Recommended Implementation

### Phase 1: MVP
Extend existing YAML + ETS architecture without database migration.

#### New Modules

**1. ChainManager Context**
```elixir
# lib/livechain/config/chain_manager.ex
defmodule Livechain.Config.ChainManager do
  # CRUD operations for chain configuration
  # Hot-reload ConfigStore after changes
  # Backup/restore functionality
end
```

**2. Enhanced Validation**
```elixir
# lib/livechain/config/config_validator.ex
defmodule Livechain.Config.ConfigValidator do
  # Comprehensive chain validation
  # Provider endpoint validation
  # Conflict detection
end
```

**3. Admin API Endpoints**
```elixir
# lib/livechain_web/controllers/admin/chain_controller.ex
# POST /api/admin/chains - Create chain
# PUT /api/admin/chains/:id - Update chain
# DELETE /api/admin/chains/:id - Delete chain
```

#### Integration Points

**ConfigStore Hot-reload**
- Reload ETS cache after YAML modifications
- Maintain zero-downtime updates
- Validate before applying changes

**Real-time Dashboard Updates**
- PubSub notifications for config changes
- LiveView auto-refresh on updates
- Error handling with rollback capability

### Phase 2: Enhanced Features

**Database Migration** (Optional)
- Ecto schemas for persistent storage
- Migration from YAML to database
- Hybrid mode support

**Advanced Validation**
- Provider endpoint health checks
- Chain compatibility validation
- Performance impact assessment

**Security & Audit**
- Rate limiting for config changes
- Audit logging for all modifications
- User authentication/authorization

## Data Structures

### Chain Configuration Schema
```elixir
%{
  id: "ethereum_mainnet",
  name: "Ethereum Mainnet",
  providers: [
    %{
      name: "alchemy",
      url: "https://eth-mainnet.g.alchemy.com/v2/...",
      weight: 0.7,
      timeout: 5000
    }
  ],
  chain_id: 1,
  block_time: 12000,
  finality_blocks: 12
}
```

### Validation Rules
- Unique chain IDs
- Valid provider URLs
- Positive weights summing to 1.0
- Reasonable timeout values
- Valid chain_id format

## API Design

### Endpoints
```
POST /api/admin/chains
PUT /api/admin/chains/:id  
DELETE /api/admin/chains/:id
GET /api/admin/chains
```

### Request/Response Format
```json
{
  "chain": {
    "id": "polygon_mainnet",
    "name": "Polygon Mainnet",
    "providers": [...],
    "chain_id": 137,
    "block_time": 2000,
    "finality_blocks": 256
  }
}
```

## Error Handling

### Validation Errors
- Detailed field-level error messages
- Rollback on validation failure
- User-friendly error display

### Runtime Errors
- Graceful degradation on config errors
- Fallback to previous valid configuration
- Monitoring and alerting integration

## Testing Strategy

### Unit Tests
- ChainManager CRUD operations
- ConfigValidator edge cases
- API endpoint responses

### Integration Tests
- End-to-end configuration workflow
- Real-time update propagation
- Error handling scenarios

### Performance Tests
- ConfigStore reload performance
- Concurrent modification handling
- Memory usage with large configurations

## Deployment Considerations

### Backwards Compatibility
- Support existing YAML configuration
- Gradual migration path
- Rollback capability

### Monitoring
- Configuration change metrics
- Performance impact tracking
- Error rate monitoring

### Security
- Input sanitization
- Rate limiting
- Audit trail maintenance

## Implementation Order

**MVP Implementation**
- ChainManager and validation
- Basic API endpoints
- Dashboard integration

**Enhanced Features**
- Advanced validation
- Security features
- Documentation and testing

## Success Metrics
- Zero downtime during config updates
- Sub-100ms ConfigStore reload time
- 100% validation coverage
- Comprehensive audit logging