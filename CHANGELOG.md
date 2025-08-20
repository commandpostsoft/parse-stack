## Parse-Stack Changelog

### 1.12.2

#### New Query Methods
- NEW: `latest` method for retrieving the most recently created object (ordered by created_at desc)
- NEW: `last_updated` method for retrieving the most recently updated object (ordered by updated_at desc)
- NEW: Both methods support count parameters and constraints like the existing `first` method
- NEW: Consistent API pattern with `first` - returns single object or array based on parameters
- NEW: Chainable `latest()` and `last_updated()` methods added to Parse::Query for method chaining with field selection and constraints

#### Query Composition and Cloning
- NEW: `clone` method for creating independent copies of Parse::Query objects with deep copying of constraints
- NEW: `Parse::Query.or(*queries)` class method for combining multiple queries with OR logic
- NEW: `Parse::Query.and(*queries)` class method for combining multiple queries with AND logic
- NEW: All query composition methods work seamlessly with aggregation pipelines and existing query operations
- NEW: Marshal-based deep copying ensures query clones are truly independent with no shared state

#### Enhanced Upsert Operations
- **IMPROVED**: `first_or_create` now follows Rails conventions - finds existing objects unchanged or creates new unsaved objects
- **IMPROVED**: `first_or_create!` enhanced to save new objects immediately while leaving existing objects unchanged
- **IMPROVED**: `create_or_update!` optimized with change detection - only saves when actual changes are detected
- NEW: Performance optimizations for upsert methods - skips unnecessary saves when no attribute changes are detected
- NEW: Enhanced Rails-style attribute merging with proper query_attrs + resource_attrs combination
- NEW: Comprehensive integration tests for all upsert methods with real Parse server validation

#### Enhanced Object Fetching
- NEW: `fetch_object` method for Parse::Pointer and Parse::Object to return fetched object instances
- **IMPROVED**: `fetch` method enhanced with optional `returnObject` parameter (defaults to true)
- NEW: Consistent object fetching behavior across both Parse::Pointer and Parse::Object classes
- NEW: Enhanced change tracking preservation after fetch operations

#### Transaction Support
- NEW: Full atomic transaction support with `Parse::Object.transaction` method
- NEW: Two transaction styles: explicit batch operations and automatic batching via return values
- NEW: Automatic retry mechanism for transaction conflicts (Parse error 251) with configurable retry limits
- NEW: Transaction rollback on any operation failure to ensure data consistency
- NEW: Support for mixed operations (create, update, delete) within single transactions
- NEW: Comprehensive transaction testing with complex business scenarios

#### Enhanced Testing Infrastructure
- NEW: Comprehensive webhook trigger testing for all trigger types (before_save, after_save, before_delete, after_delete, before_find, after_find)
- NEW: Request idempotency system with `_RB_` prefix for Ruby-initiated requests to prevent duplicate operations
- NEW: Intelligent webhook callback coordination to distinguish between Ruby vs client-initiated operations
- NEW: Docker-based Parse Server integration testing environment with Redis caching support
- NEW: Complete test coverage for cache integration, date/timezone handling, batch operations, and model associations
- NEW: Query aggregation pipeline tests with proper pointer conversion and MongoDB field handling
- NEW: Cloud config variable testing for reading/writing Parse configuration settings
- NEW: Integration tests for enhanced change tracking with after_save hook validation
- NEW: Performance comparison testing for upsert methods with timing validation
- IMPROVED: Webhook payload detection with `ruby_initiated?` and `client_initiated?` helper methods
- IMPROVED: Smart callback skipping for Ruby operations to prevent callback loops
- IMPROVED: Thread-safe request ID generation and configuration management

#### Test Categories Added
- Cache integration tests (Redis TTL, invalidation, authentication contexts)
- Date and timezone handling tests (UTC conversion, DST transitions)
- Batch operations and transaction tests (atomic operations, rollback scenarios)
- Query pointer and aggregation tests (MongoDB field conversion, arrays of pointers)
- Model association tests (has_many, has_one, belongs_to with various strategies)
- Request idempotency tests (configuration, thread safety, per-request control)
- Webhook callback coordination tests (Ruby vs client detection, error handling)
- Webhook trigger tests (all trigger types with proper underscore naming convention)

#### New Query Constraints
- NEW: `readable_by` constraint for filtering objects by ACL read permissions for users/roles
- NEW: `writable_by` constraint for filtering objects by ACL write permissions for users/roles
- NEW: `between` constraint for range queries on numbers, dates, strings (alphabetical), and comparable values (combines $gte and $lte)
- NEW: Smart input handling for User objects, Role objects, Pointers, and role name strings
- NEW: Automatic role fetching when given User objects to include user's roles in permission checks
- NEW: Support for both ACL object field and Parse's internal _rperm/_wperm fields
- NEW: Public access ("*") automatically included when querying internal permission fields

### 1.12.1

#### Query and Pointer Improvements
- IMPROVED: Schema-based approach for pointer conversion when available - provides more reliable pointer field detection
- IMPROVED: Enhanced `in` and `not_in` query constraints to properly handle Parse pointers 
- IMPROVED: Automatic conversion of pointer strings to proper Parse::Pointer objects in queries
- NEW: Support for detecting pointer fields from schema information when available
- NEW: Fallback to pattern-based detection when schema is unavailable
- FIXED: Pointer conversion in aggregation queries now correctly handles all pointer field types

### 1.12.0

#### Breaking Changes
- **BREAKING**: `distinct` method now returns object IDs directly by default for pointer fields instead of full pointer hash objects like `{"__type"=>"Pointer", "className"=>"Team", "objectId"=>"abc123"}`. Use `distinct(field, return_pointers: true)` to get Parse::Pointer objects.
- **BREAKING**: Minimum Ruby version is now 3.2+ (dropped support for Ruby < 3.2)
- **BREAKING**: Updated to Faraday 2.x and removed `faraday_middleware` dependency
- **BREAKING**: Fixed typo "constaint" to "constraint" throughout codebase

#### New Aggregation Functions
- NEW: `sum(field)` - Calculate sum of numeric values across matching records
- NEW: `min(field)` - Find minimum value for a field  
- NEW: `max(field)` - Find maximum value for a field
- NEW: `average(field)` / `avg(field)` - Calculate average value for numeric fields
- NEW: `count_distinct(field)` - Count unique values using MongoDB aggregation pipeline

#### Enhanced Group By Operations  
- NEW: `group_by(field, options)` - Group records by field value with aggregation support
- NEW: `group_by_date(field, interval, options)` - Group by date intervals (:year, :month, :week, :day, :hour)
- NEW: `group_objects_by(field, options)` - Group actual object instances (not aggregated)
- NEW: Sortable grouping with `sortable: true` option and `SortableGroupBy`/`SortableGroupByDate` classes
- NEW: Array flattening with `flatten_arrays: true` for multi-value fields
- NEW: Pointer optimization with `return_pointers: true` for memory efficiency

#### Advanced Query Constraints
- NEW: `equals_linked_pointer` - Compare pointer fields across linked objects using aggregation
- NEW: `does_not_equal_linked_pointer` - Negative comparison of linked pointers  
- NEW: `between_dates` - Query records within date/time ranges
- NEW: `between` - General range constraint for numbers, dates, and comparable values (combines $gte and $lte)
- NEW: `matches_key_in_query` - Matches key in subquery
- NEW: `does_not_match_key_in_query` - Does not match key in subquery
- NEW: `starts_with` - String prefix matching constraint
- NEW: `contains` - String substring matching constraint

#### New Utility Methods
- NEW: `pluck(field)` - Extract values for single field from all matching records
- NEW: `to_table(columns, options)` - Format results as ASCII/CSV/JSON tables with sorting
- NEW: `verbose_aggregate` - Debug flag for MongoDB aggregation pipeline details
- NEW: `keys(*fields)` / `select_fields(*fields)` - Field selection optimization
- NEW: `result_pointers` - Get Parse::Pointer objects instead of full objects
- NEW: `distinct_objects(field)` - Get distinct values with populated objects

#### Enhanced Cloud Functions
- NEW: `call_function_with_session(name, body, session_token)` - Call cloud functions with session context
- NEW: `trigger_job_with_session(name, body, session_token)` - Trigger background jobs with session token
- NEW: Enhanced authentication options and master key support for cloud functions

#### Result Processing & Display
- NEW: `GroupedResult` class with built-in sorting capabilities (`sort_by_key_asc/desc`, `sort_by_value_asc/desc`)
- NEW: Table formatting with custom headers, sorting, and multiple output formats (ASCII, CSV, JSON)
- NEW: Enhanced result processing with pointer optimization across all aggregation methods

#### Pointer & Object Handling Improvements
- IMPROVED: Enhanced `distinct` with automatic detection and conversion of MongoDB pointer strings
- IMPROVED: `return_pointers` option available across multiple methods for memory optimization
- IMPROVED: Server-side object population in aggregation pipelines
- IMPROVED: Automatic handling of `ClassName$objectId` format conversion

#### Dependency Updates
- UPDATED: ActiveModel and ActiveSupport to latest compatible versions
- UPDATED: Rack dependency
- UPDATED: Modernized for Ruby 3.2+ compatibility

### 1.11.3
- Adds "empty" query constraint option
- Adds "include" alias for "includes" query method

### 1.11.1
- Always applies attribute changes in first_or_create resource_attrs argument

### 1.11.0
- Adds create_or_update! method

### 1.10.3
- Fixes potential crash caused by activerecord gem version 6+

### 1.10.0

- Adds support for Ruby 3+ style hash and block arguments.

### 1.9.0

- Support for ActiveModel and ActiveSupport 6.0.
- Fixes `as_json` tests related to changes.
- Support for Faraday 1.0 and FaradayMiddleware 1.0
- Minimum Ruby version is now `>= 2.5.0`

### 1.8.0

- NEW: Support for Parse Server [full text search](https://github.com/modernistik/parse-stack#full-text-search-constraint) with the `text_search` operator. Related to [Issue#46](https://github.com/modernistik/parse-stack/issues/46).
- NEW: Support for `:distinct` aggregation query. Finds the distinct values for a specified field across a single collection or view and returns the results in an array.
  For example, `User.distinct(:city, :created_at.after => 3.days.ago)` to return an array of unique city names for which records were created in the last 3 days.

### 1.7.4

- NEW: Added `parse_object` extension to Hash classes to more easily call
  Parse::Object.build in `map` loops with symbol to proc.
- CHANGED: Renamed `hyperdrive_config!` to `Parse::Hyperdrive.config!`
- REMOVED: The used of non-JSON dates has been removed for `createdAt` and `updatedAt`
  fields as all Parse SDKs now support the new JSON format. `Parse.disable_serialized_string_date`
  has also been removed so that `created_at` and `updated_at` return the same value
  as `createdAt` and `updatedAt` respectively.
- FIXED: Builder properly auto generates Parse Relation associations using `through: :relation`.
- REMOVED: Defining `has_many` or `belongs_to` associations more than once will no longer result
  in an `ArgumentError` (they are now warnings). This will allow you to define associations for classes before calling `auto_generate_models!`
- CHANGED: Parse::CollectionProxy now supports `parse_objects` and `parse_pointers` for compatibility with the
  sibling `Array` methods. Having an Parse-JSON Hash array or a Parse::CollectionProxy which contains a series
  of Parse hashes can now be easily converted to an array of Parse objects with these methods.
- FIXED: Correctly discards ACL changes on User model saves.
- FIXED: Fixes issues with double '/' in update URI paths.

### 1.7.3

- CHANGED: Moved to using preferred ENV variable names based on parse-server cli.
- CHANGED: Default url is now http://localhost:1337/parse
- NEW: Added method `hyperdrive_config!` to apply remote ENV from remote JSON url.

### 1.7.2

- NEW: `Parse::Model.autosave_on_create` has been removed in favor of `first_or_create!`.
- NEW: Webhook Triggers and Functions now have a `wlog` method, similar to `puts`, but allows easier tracing of
  single requests in a multi-request threaded environment. (See Parse::Webhooks::Payload)
- NEW: `:id` constraints also safely supports pointers by skipping class matching.
- NEW: Support for `add_unique` and the set union operator `|` in collection proxies.
- NEW: Support for `uniq` and `uniq!` in collection proxies.
- NEW: `uniq` and `uniq!` for collection proxies utilize `eql?` for determining uniqueness.
- NEW: Updated override behavior for the `hash` method in Parse::Pointer and subclasses.
- NEW: Support for additional array methods in collection proxies (+,-,& and |)
- NEW: Additional methods for Parse::ACL class for setting read/write privileges.
- NEW: Expose the shared cache store through `Parse.cache`.
- NEW: `User#any_session!` method, see documentation.
- NEW: Extension to support `Date#parse_date`.
- NEW: Added `Parse::Query#append` as alias to `Parse::Query#conditions`
- CHANGED: `save_all` now returns true if there were no errors.
- FIXED: first_or_create will now apply dirty tracking to newly created fields.
- FIXED: Properties of :array type will always return a Parse::CollectionProxy if
  their internal value is nil. The object will not be marked dirty until something is added to the array.
- FIXED: Encoding a Parse::Object into JSON will remove any values that are `nil`
  which were not explicitly changed to that value.
- [PR#39](https://github.com/modernistik/parse-stack/pull/39): Allow Moneta::Expires
  as cache object to allow for non-native expiring caches by [GrahamW](https://github.com/GrahamW)

### 1.7.1

- NEW: `:timezone` datatype that maps to `Parse::TimeZone` (which mimics `ActiveSupport::TimeZone`)
- NEW: Installation `:time_zone` field is now a `Parse::TimeZone` instance.
- Any properties named `time_zone` or `timezone` with a string data type set will be converted to use `Parse::TimeZone` as the data class.
- FIXED: Fixes issues with HTTP Method Override for long url queries.
- FIXED: Fixes issue with Parse::Object.each method signature.
- FIXED: Removed `:id` from the Parse::Properties::TYPES list.
- FIXED: Parse::Object subclasses will not be allowed to redefine core properties.
- Parse::Object save_all() and each() methods raise ArgumentError for
  invalid constraint arguments.
- Removes deprecated function `Role.apply_default_acls`. If you need the previous
  behavior, you should set your own :before_save callback that modifies the role
  object with the ACLs that you want or use the new `Role.set_default_acl`.
- Parse::Object.property returns true/false whether creating the property was successful.
- Parse::Session now has a `has_one` association to Installation through `:installation`
- Parse::User now has a `has_many` association to Sessions through `:active_sessions`
- Parse::Installation now has a `has_one` association to Session through `:session`

### 1.7.0

- NEW: You can use `set_default_acl` to set default ACLs for your subclasses.
- NEW: Support for `withinPolygon` query constraint.
- Refactoring of the default ACL system and deprecation of `Parse::Object.acl`
- Parse::ACL.everyone returns an ACL instance with public read and writes.
- Documentation updates.

### 1.6.12

- NEW: Parse.use_shortnames! to utilize shorter class methods. (optional)
- NEW: parse-console supports `--url` option to load config from JSON url.
- FIXES: Issue #27 where core classes could not be auto-upgraded if they were missing.
- Warnings are now printed if auto_upgrade! is called without the master key.
- Use `Parse.use_shortnames!` to use short name class names Ex. Parse::User -> User
- Hosting documentation on https://www.modernistik.com/gems/parse-stack/ since rubydoc.info doesn't
  use latest yard features.
- Parse::Query will raise an exception if a non-nil value is passed to `:session` that
  does not provide a valid session token string.
- `save` and `destroy` will raise an exception if a non-nil `session` argument is passed
  that does not provide a valid session token string.
- Additional documentation changes and tests.

### 1.6.11

- NEW: Parse::Object#sig method to get quick information about an instance.
- FIX: Typo fix when using Array#objectIds.
- FIX: Passing server url in parse-console without the `-s` option when using IRB.
- Exceptions will not be raised on property redefinitions, only warning messages.
- Additional tests.
- Short name classes are generated when using parse-console. Ex. Parse::User -> User
- parse-console supports `--config-sample` to generate a sample configuration file.

### 1.6.7

- Default SERVER_URL changed to http://localhost:1337/parse
- NEW: Command line tool `parse-console` to do interactive Parse development with parse-stack.
- REMOVED: Deprecated parse.com specific APIs under the `/apps/` path.

### 1.6.5

- Client handles HTTP Status 429 (RetryLimitExceeded)
- Role class does not automatically set default ACLs for Roles. You can restore
  previous behavior by using `before_save :apply_default_acls`.
- Fixed minor issue to Parse::User.signup when merging username into response.
- NEW: Adds Parse::Product core class.
- NEW: Rake task to list registered webhooks. `rake parse:webhooks:list`
- Experimental support for beforeFind and afterFind - though webhook support not
  yet fully available in open source Parse Server.
- Removes HTTPS requirement on webhooks.
- FIXES: Issue with WEBHOOK_KEY not being properly validated when set.
- beforeSaves now return empty hash instead of true on noop changes.

### 1.6.4

- Fixes #20: All temporary headers values are strings.
- Reduced cache storage consumption by only storing response body and headers.
- Increased maximum cache content length size to 1.25 MB.
- You may pass a redis url to the :cache option of setup.
- Fixes issue with invalid struct size of Faraday::Env with old caching keys.
- Added server_info and health check APIs for Parse-Server +2.2.25.
- Updated test to validate against MT6.

### 1.6.1

- NEW: Batch requests are now parallelized.
- `skip` in queries no longer capped to 10,000.
- `limit` in queries no longer capped at 1000.
- `all()` queries can now return as many results as possible.
- NEW: `each()` method on Parse::Object subclasses to iterate
  over all records in the colleciton.

### 1.6.0

- NEW: Auto generate models based on your remote schema.
- The default server url is now 'http://localhost:1337/parse'.
- Improves thread-safety of Webhooks middleware.
- Performance improvements.
- BeforeSave change payloads do not include the className field.
- Reaches 100% documentation (will try to keep it up).
- Retry mechanism now configurable per client through `retry_limit`.
- Retry now follows sampling back-off delay algorithm.
- Adds `schemas` API to retrieve all schemas for an application.
- :number can now be used as an alias for the :integer data type.
- :geo_point can now be used as an alias for the :geopoint data type.
- Support accessing properties of Parse::Object subclasses through the [] operator.
- Support setting properties of Parse::Object subclasses through the []= operator.
- :to_s method of Parse::Date returns the iso8601(3) by default, if no arguments are provided.
- Parse::ConstraintError has been removed in favor of ArgumentError.
- Parse::Payload has been placed under Parse::Webhooks::Payload for clarity.
- Parse::WebhookErrorResponse has been moved to Parse::Webhooks::ResponseError.
- Moves Parse::Object modular functionality under Core namespace
- Renames ClassBuilder to Parse::Model::Builder
- Renamed SaveFailureError to RecordNotSaved for ActiveRecord similarity.
- All Parse errors inherit from Parse::Error.

### 1.5.3

- Several fixes and performance improvements.
- Major revisions to documentation.
- Support for increment! and decrement! for Integer and Float properties.

### 1.5.2

- FIXES #16: Constraints to `count` were not properly handled.
- FIXES #15: Incorrect call to `request_password_reset`.
- FIXES #14: Typos
- FIXES: Issues when passing a block to chaining scope.
- FIXES: Enums properly handle default values.
- FIXES: Enums macro methods now are dirty tracked.
- FIXES: #17: overloads inspect to show objects in a has_many scope.
- `reload!` and session methods support client request options.
- Proactively deletes possible matching cache keys on non GET requests.
- Parse::File now has a `force_ssl` option that makes sure all urls returned are `https`.
- Documentation
- ParseConstraintError is now Parse::ConstraintError.
- All constraint subclasses are under the Constraint namespace.

### 1.5.1

- BREAKING CHANGE: The default `has_many` implementation is `:query` instead of `:array`.
- NEW: Support for `has_one` type of associations.
- NEW: `has_many` associations support `Query` implementation as the inverse of `:belongs_to`.
- NEW: `has_many` and `has_one` associations support scopes as second parameter.
- NEW: Enumerated property types that mimic ActiveRecord::Enum behavior.
- NEW: Support for scoped queries similar to ActiveRecord::Scope.
- NEW: Support updating Parse config using `set_config` and `update_config`
- NEW: Support for user login, logout and sessions.
- NEW: Support for signup, including signing up with third-party services.
- NEW: Support for linking and unlinking user accounts with third-party services.
- NEW: Improved support for Parse session APIs.
- NEW: Boolean properties automatically generate a positive query scope for the field.
- Added property options for `:scopes`, `:enum`, `:_prefix` and `:_suffix`
- FIX: Auto-upgrade did not upgrade core classes.
- FIX: Pointer and Relation collection proxies will delay pointer casting until update.
- Improves JSON encoding/decoding performance.
- Removes throttling of requests.
- Turns off cache when using `save_all` method.
- Parse::Query supports ActiveModel::Callbacks for `:prepare`.
- Subclasses now support a :create callback that is only executed after a new object is successfully saved.
- Added alias method :execute! for Parse::Query#fetch! for clarity.
- `Parse::Client.session` has been deprecated in favor of `Parse::Client.client`
- All Parse-Stack errors that are raised inherit from StandardError.
- All :object data types is now cast as ActiveSupport::HashWithIndifferentAccess.
- :boolean properties now have a special `?` method to access true/false values.
- Adds chaining to Parse::Query#conditions.
- Adds alias instance method `Parse::Query#query` to `Parse::Query#conditions`.
- `Parse::Object.where` is now an alias to `Parse::Object.query`. You can now use `Parse::Object.where_literal`.
- Parse::Query and Parse::CollectionProxy support Enumerable mixin.
- Parse::Query#constraints allow you to combine constraints from different queries.
- `Parse::Object#validate!` can be used in webhook to throw webhook error on failed validation.

### 1.4.3

- NEW: Support for rails generators: `parse_stack:install` and `parse_stack:model`.
- Support Parse::Date with ActiveSupport::TimeWithZone.
- :date properties will now raise an error if value was not converted to a Parse::Date.
- Support for calling `before_save` and `before_destroy` callbacks in your model when a Parse::Object is returned by your `before_save` or `before_delete` webhook respectively.
- Parse::Query `:cache` expression now allows integer values to define the specific cache duration for this specific query request. If `false` is passed, will ignore the cache and make the request regardless if a cache response is available. If `true` is passed (default), it will use the value configured when setting up when calling `Parse.setup`.
- Fixes the use of `:use_master_key` in Parse::Query.
- Fixes to the cache key used in middleware.
- Parse::User before_save callback clears the record ACLs.
- Added `anonymous?` instance method to `Parse::User` class.

### 1.3.8

- Support for reloading the Parse config data with `Parse.config!`.
- The Parse::Request object is now provided in the Parse::Response instance.
- The HTTP status code is provided in `http_status` accessor for a Parse::Response.
- Raised errors now provide info on the request that failed.
- Added new `ServiceUnavailableError` exception for Parse error code 2 and HTTP 503 errors.
- Upon a `ServiceUnavailableError`, we will retry the request one more time after 2 seconds.
- `:not_in` and `:contains_all` queries will format scalar values into an array.
- `:exists` and `:null` will raise `ConstraintError` if non-boolean values are passed.
- NEW: `:id` constraint to allow passing an objectId to a query where we will infer the class.

### 1.3.7

- Fixes json_api loading issue between ruby json and active_model_serializers.
- Fixes loading active_support core extensions.
- Support for passing a `:session_token` as part of a Parse::Query.
- Default mime-type for Parse::File instances is `image/jpeg`. You can override the default by setting
  `Parse::File.default_mime_type`.
- Added `Parse.config` for easy access to `Parse::Client.client(:default).config`
- Support for `Parse.auto_upgrade!` to easily upgrade all schemas.
- You can import useful rake tasks by requiring `parse/stack/tasks` in your rake file.
- Changes the format in `select` and `reject` queries (see documentation).
- Latitude and longitude values are now validated with warnings. Will raise exceptions in the future.
- Additional alias methods for queries.
- Added `$within` => `$box` GeoPoint query. (see documentation)
- Improves support when using Parse-Server.
- Major documentation updates.
- `limit` no longer defaults to 100 in `Parse::Query`. This will allow Parse-Server to determine default limit, if any.
- `:bool` property type has been added as an alias to `:boolean`.
- You can turn off formatting field names with `Parse::Query.field_formatter = nil`.

### 1.3.1

- Parse::Query now supports `:cache` and `:use_master_key` option. (experimental)
- Minimum ruby version set to 1.9.3 (same as ActiveModel 4.2.1)
- Support for Rails 5.0+ and Rack 2.0+

### 1.3.0

- **IMPORTANT**: **Raising an error no longer sends an error response back to
  the client in a Webhook trigger. You must now call `error!('...')` instead of
  calling `raise '...'`.** The webhook block is now binded to the Parse::Webhooks::Payload
  instance, removing the need to pass `payload` object; use the instance methods directly.
  See updated README.md for more details.
- **Parse-Stack will throw new exceptions** depending on the error code returned by Parse. These
  are of type AuthenticationError, TimeoutError, ProtocolError, ServerError, ConnectionError and RequestLimitExceededError.
- `nil` and Delete operations for `:integers` and `:booleans` are no longer typecast.
- Added aliases `before`, `on_or_before`, `after` and `on_or_after` to help with
  comparing non-integer fields such as dates. These map to `lt`,`lte`, `gt` and `gte`.
- Schema API return true is no changes were made to the table on `auto_upgrade!` (success)
- Parse::Middleware::Caching no longer caches 404 and 410 responses; and responses
  with content lengths less than 20 bytes.
- FIX: Parse::Payload when applying auth_data in Webhooks. This fixes handing Facebook
  login with Android devices.
- New method `save!` to raise an exception if the save fails.
- FIX: Verify Content-Type header field is present for webhooks before checking its value.
- FIX: Support `reload!` when using it Padrino.

### 1.2.1

- Add active support string dependencies.
- Support for handling the `Delete` operation on belongs_to
  and has_many relationships.
- Documentation changes for supported Parse atomic operations.

### 1.2

- Fixes issues with first_or_create.
- Fixes issue when singularizing :belongs_to and :has_many property names.
- Makes sure time is sent as UTC in queries.
- Allows for authData to be applied as an update to a before_save for a Parse::User.
- Webhooks allow for returning empty data sets and `false` from webhook functions.
- Minimum version for ActiveModel and ActiveSupport is now 4.2.1

### 1.1

- In Query `join` has been renamed to `matches`.
- Not In Query `exclude` has been renamed to `excludes` for consistency.
- Parse::Query now has a `:keys` operation to be usd when passing sub-queries to `select` and `matches`
- Improves query supporting `select`, `matches`, `matches` and `excludes`.
- Regular expression queries for `like` now send regex options

### 1.0.10

- Fixes issues with setting default values as dirty when using the builder or before_save hook.
- Fixes issues with autofetching pointers when default values are set.

### 1.0.8

- Fixes issues when setting a collection proxy property with a collection proxy.
- Default array values are now properly casted as collection proxies.
- Default booleans values of `false` are now properly set.

### 1.0.7

- Fixes issues when copying dates.
- Fixes issues with double-arrays.
- Fixes issues with mapping columns to atomic operations.

### 1.0.6

- Fixes issue when making batch requests with special prefix url.
- Adds Parse::ConnectionError custom exception type.
- You can call locally registered cloud functions with
  Parse::Webhooks.run_function(:functionName, params) without going through the
  entire Parse API network stack.
- `:symbolize => true` now works for `:array` data types. All items in the collection
  will be symbolized - useful for array of strings.
- Prevent ACLs from causing an autofetch.
- Empty strings, arrays and `false` are now working with `:default` option in properties.

### 1.0.5

- Defaults are applied on object instantiation.
- When applying default values, dirty tracking is called.

### 1.0.4

- Fixes minor issue when storing and retrieving objects from the cache.
- Support for providing :server_url as a connection option for those migrating hosting
  their own parse-server.

### 1.0.3

- Fixes minor issue when passing `nil` to the class `find` method.

### 1.0.2

- Fixes internal issue with `operate_field!` method.
