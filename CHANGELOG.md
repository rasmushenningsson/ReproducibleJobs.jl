# ReproducibleJobs.jl changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-08-17

### Fixed

* Fix hash collisions for some numeric and string types, causing deduplication to fail. Examples of cases fixed: `[0,0]` and `[0.0,0.0]`, `[1,2]` and `UInt64[1,2]`, `[v"1.2.3"]` and `["1.2.3"]`. This changes a lot of hashes so recomputations are expected.

## [0.1] - 2026-06-24

### Added

* Initial release of the ReproducibleJobs.jl package.
