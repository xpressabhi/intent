# Store audit history in relational tables

## Request

Persist a durable audit history for changes to account settings.

## Context

The service already uses a relational database, but it does not retain a queryable history of account-setting changes.

## Proposed design

Add an audit table to the existing database and write one row for each setting change. Keep the current settings table as the source of truth and expose a read-only history endpoint.

## Constraints

Keep event reads backward compatible and avoid adding another storage service.
