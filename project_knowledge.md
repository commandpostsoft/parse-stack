# Parse Stack Project Knowledge

## Overview
Parse Stack is a comprehensive Ruby SDK/ORM for Parse Server that provides a full-featured, ActiveModel-compliant interface for building Parse-based applications in Ruby. Originally supporting Parse.com, it now focuses on open-source Parse Server deployments.

## Architecture

### Core Components

#### 1. Model Layer (`Parse::Object`)
- Base class providing ActiveModel integration
- Handles object lifecycle (create, read, update, delete)
- Automatic field mapping between Ruby snake_case and Parse camelCase
- Built-in properties: id, created_at, updated_at, acl
- State management: new?, existed?, persisted?
- JSON serialization with pointer support

#### 2. Property System
Dynamic property definitions with type conversion:
- **Basic Types**: string, integer, float, boolean, date
- **Parse Types**: file, geopoint, bytes, pointer, array, object
- **Special Types**: acl, timezone
- **Features**:
  - Default values (static or Proc-based)
  - Enum support with validation
  - Dirty tracking
  - Automatic type conversion
  - Operation support (increment, add, remove)

#### 3. Client Layer
Low-level REST API client built on Faraday:
- Multi-session support (multiple Parse apps)
- Middleware stack (authentication, caching, body building)
- Automatic retry with exponential backoff
- Comprehensive error handling
- Request/Response objects with Parse protocol support

#### 4. Query System
DataMapper-inspired query interface:
- Chainable constraints (where, or_where, limit, skip)
- Rich operators (eq, ne, lt, gt, in, contains, matches, etc.)
- Lazy loading with enumerable interface
- Query caching and compilation
- Schema validation
- Callbacks (before_prepare, after_prepare)

#### 5. Association System
Multiple relationship patterns:
- **belongs_to**: One-to-one via pointer field
- **has_one**: Inverse one-to-one relationship
- **has_many**: Three strategies:
  - Query-based (foreign key)
  - Array-based (Parse Array column)
  - Relation-based (Parse Relation type)
- Collection proxies for lazy loading

## API Modules

### Core APIs
- **Objects API**: CRUD operations for Parse objects
- **Users API**: Authentication, signup, login, password reset
- **Sessions API**: Session token management
- **Files API**: File upload/download with S3/GCS support
- **Schema API**: Schema introspection and modification
- **Cloud Functions**: Remote function invocation
- **Push API**: Push notification support
- **Analytics API**: Event tracking
- **Batch API**: Batch operations for efficiency
- **Config API**: Application configuration management
- **Aggregations API**: MongoDB-style aggregation pipelines

## Built-in Parse Classes

### User Management
```ruby
class Parse::User < Parse::Object
  # Authentication
  - signup(username, password, email, **attributes)
  - login(username, password)
  - logout
  - request_password_reset(email)
  
  # OAuth Support
  - autologin_service(service, auth_data)
  
  # Session Management
  - session_token
  - authenticated?
end
```

### Role-Based Access Control
```ruby
class Parse::Role < Parse::Object
  # Manages user groups and permissions
  - name (unique identifier)
  - users (relation to User)
  - roles (relation to Role for nesting)
end
```

### Push Notifications
```ruby
class Parse::Installation < Parse::Object
  # Device registration for push
  - deviceType (ios, android, etc.)
  - deviceToken
  - channels (subscription array)
  - badge, timeZone, appIdentifier
end
```

### Session Management
```ruby
class Parse::Session < Parse::Object
  # Tracks user sessions
  - sessionToken
  - user (pointer to User)
  - expiresAt
  - installationId
end
```

## Data Types

### GeoPoint
```ruby
Parse::GeoPoint.new(latitude, longitude)
# Supports distance queries and geo-fencing
```

### File
```ruby
Parse::File.new(data, filename, content_type)
# Handles file uploads with automatic URL generation
```

### ACL (Access Control List)
```ruby
acl = Parse::ACL.new
acl.everyone(read: true, write: false)
acl.user(user, read: true, write: true)
acl.role("Admin", read: true, write: true)
```

### Date
```ruby
Parse::Date.new(value)
# ISO8601 formatting with timezone support
```

### Bytes
```ruby
Parse::Bytes.new(data)
# Base64 encoded binary data
```

### TimeZone
```ruby
Parse::TimeZone.new("America/New_York")
# IANA timezone identifiers
```

## Query Operations

### Basic Queries
```ruby
# Simple equality
Song.query(title: "My Song")

# Multiple conditions (AND)
Song.query(artist: artist, year: 2023)

# Range queries
Song.query(plays: 100..1000)
Song.query(created_at: 1.week.ago..)
```

### Advanced Constraints
```ruby
# Comparison operators
query(:price.lt => 100)        # less than
query(:price.lte => 100)       # less than or equal
query(:price.gt => 50)         # greater than
query(:price.gte => 50)        # greater than or equal
query(:price.ne => 75)         # not equal

# Array operations
query(:tags.in => ["rock", "pop"])          # contains any
query(:tags.all => ["rock", "pop"])         # contains all
query(:tags.size => 3)                      # array size

# String operations
query(:title.starts_with => "The")
query(:title.ends_with => "Song")
query(:description.like => "%keyword%")

# Geo queries
query(:location.near => geopoint, max_distance: 10)
query(:location.within_box => [sw_corner, ne_corner])

# Relational queries
query(:artist.matches => artist_query)      # subquery
query(:comments.in_query => comment_query)  # relation query

# Existence
query(:optional_field.exists => true)
query(:deleted_field.exists => false)
```

### Query Chaining
```ruby
Song.query(:year.gt => 2020)
    .where(:genre.in => ["rock", "indie"])
    .or_where(:featured => true)
    .order(:plays.desc)
    .limit(20)
    .skip(40)
    .includes(:artist, :album)  # eager loading
    .cache(1.hour)              # result caching
```

## Associations

### Define Relationships
```ruby
class Artist < Parse::Object
  has_many :songs, -> { query(verified: true) }
  has_many :albums
  has_one :profile
  has_many :genres, field: :genre_list  # array-based
  has_many :followers, as: :relation    # Parse Relation
end

class Song < Parse::Object
  belongs_to :artist
  belongs_to :album
  has_many :comments
end
```

### Working with Associations
```ruby
# Access associations
artist.songs              # returns query proxy
artist.songs.count        # efficient count query
artist.songs.each { }     # lazy enumeration

# Modify associations
artist.songs.add(song)
artist.songs.remove(song)
artist.songs.destroy_all

# Array-based associations
artist.genres << "rock"
artist.genres.remove("pop")

# Relation associations (many-to-many)
artist.followers.add(user1, user2)
artist.followers.remove(user3)
```

## Callbacks and Validations

### Lifecycle Callbacks
```ruby
class Article < Parse::Object
  before_create :set_defaults
  after_create :send_notification
  before_save :update_slug
  after_save :clear_cache
  before_destroy :check_permissions
  after_destroy :cleanup_files
  
  # Webhook triggers
  before_save_trigger do
    # Runs in Parse Cloud Code
    validate_content
  end
end
```

### Validations (ActiveModel)
```ruby
class Product < Parse::Object
  validates :name, presence: true, length: { minimum: 3 }
  validates :price, numericality: { greater_than: 0 }
  validates :sku, uniqueness: true
  validate :custom_validation
  
  def custom_validation
    errors.add(:base, "Invalid state") if invalid_state?
  end
end
```

## Configuration

### Basic Setup
```ruby
Parse.setup(
  server_url: 'https://your-parse-server.com/parse',
  application_id: 'your_app_id',
  api_key: 'your_api_key',        # REST API key
  master_key: 'your_master_key'   # Optional, for admin operations
)
```

### Advanced Configuration
```ruby
Parse::Client.setup(
  # Connection settings
  server_url: ENV['PARSE_SERVER_URL'],
  application_id: ENV['PARSE_APP_ID'],
  api_key: ENV['PARSE_API_KEY'],
  
  # Caching
  cache: Moneta.new(:Redis, url: ENV['REDIS_URL']),
  expires: 1.hour,
  
  # HTTP settings
  adapter: :typhoeus,  # or :net_http, :patron, etc.
  timeout: 30,
  
  # Error handling
  max_retries: 3,
  raise_on_save_failure: true,
  
  # Logging
  logging: true,
  logger: Rails.logger,
  
  # Field formatting
  columnize: true  # Convert snake_case to camelCase
)
```

### Multiple Applications
```ruby
# Define multiple connections
Parse::Client.setup(:app1, 
  server_url: 'https://app1.parse.com/parse',
  application_id: 'app1_id'
)

Parse::Client.setup(:app2,
  server_url: 'https://app2.parse.com/parse', 
  application_id: 'app2_id'
)

# Use specific connection
class App1Model < Parse::Object
  parse_client :app1
end
```

## Webhooks

### Setup Webhooks
```ruby
# In your webhook controller
class ParseWebhooksController < ApplicationController
  include Parse::Webhooks
  
  # Define function
  function :calculatePrice do |params|
    product = Product.find(params["productId"])
    { price: product.calculate_price }
  end
  
  # Define triggers
  trigger :beforeSave, "Product" do |object|
    object["name"] = object["name"].strip.capitalize
    object
  end
end
```

### Webhook Registration
```ruby
# Register webhooks with Parse Server
Parse::Webhooks.register_functions!
Parse::Webhooks.register_triggers!
```

## Rails Integration

### Setup (via Railtie)
```ruby
# Gemfile
gem 'parse-stack'

# config/initializers/parse.rb
Parse.setup(
  server_url: Rails.application.credentials.parse[:server_url],
  application_id: Rails.application.credentials.parse[:app_id],
  api_key: Rails.application.credentials.parse[:api_key]
)
```

### Generators
```bash
# Generate Parse models
rails generate parse:model Song
rails generate parse:model User  # extends Parse::User
rails generate parse:webhooks
```

### ActiveRecord-like Interface
```ruby
# Models work like ActiveRecord
song = Song.new(title: "New Song")
song.save!

Song.create!(title: "Another Song")
Song.find_by(title: "My Song")
Song.where(year: 2023).order(:plays).limit(10)
```

## Performance Optimization

### Caching Strategies
```ruby
# Query result caching
songs = Song.query(featured: true).cache(5.minutes)

# Object caching
song = Song.find("abc123", cache: true)

# Global cache configuration
Parse::Client.setup(
  cache: Moneta.new(:LRUHash, expires: true),
  expires: 300
)
```

### Batch Operations
```ruby
# Batch create/update/delete
batch = Parse::Client.batch
batch.add_request(song1.save_request)
batch.add_request(song2.save_request)
batch.add_request(song3.destroy_request)
results = batch.submit!
```

### Eager Loading
```ruby
# Include associations to prevent N+1
songs = Song.includes(:artist, :album).limit(50)
```

### Field Selection
```ruby
# Only fetch needed fields
songs = Song.select(:title, :artist).limit(100)
```

## Error Handling

### Parse Errors
```ruby
begin
  song.save!
rescue Parse::Error => e
  case e.code
  when Parse::Error::OBJECT_NOT_FOUND
    # Handle missing object
  when Parse::Error::INVALID_SESSION_TOKEN
    # Re-authenticate user
  when Parse::Error::DUPLICATE_VALUE
    # Handle unique constraint violation
  end
end
```

### Validation Errors
```ruby
if song.valid?
  song.save
else
  song.errors.full_messages.each do |msg|
    puts "Validation error: #{msg}"
  end
end
```

## Security

### ACLs (Access Control Lists)
```ruby
# Object-level permissions
song = Song.new
song.acl.everyone(read: true, write: false)
song.acl.user(current_user, read: true, write: true)
song.acl.role("Moderator", read: true, write: true)
song.save

# Default ACLs per class
Song.set_default_acl do |acl|
  acl.everyone(read: true)
  acl.role("Admin", write: true)
end
```

### Master Key Usage
```ruby
# Use master key for admin operations
Parse::Client.setup(master_key: ENV['PARSE_MASTER_KEY'])

# Bypass ACLs with master key
Song.query.use_master_key.each do |song|
  # Access all objects regardless of ACL
end
```

## Testing

### Test Configuration
```ruby
# spec/support/parse.rb
RSpec.configure do |config|
  config.before(:suite) do
    Parse.setup(
      server_url: 'http://localhost:1337/parse',
      application_id: 'test_app',
      api_key: 'test_key'
    )
  end
  
  config.before(:each) do
    # Clear test data
    Song.destroy_all
  end
end
```

### Mocking Parse Requests
```ruby
# Using WebMock or VCR
VCR.use_cassette('parse_requests') do
  song = Song.create(title: "Test Song")
  expect(song.id).to be_present
end
```

## Migration from Parse.com

### Key Differences
1. Server URL must be specified (no default)
2. REST API key required (not client key)
3. Master key optional but recommended
4. Cloud Code functions via webhooks
5. File storage requires configuration

### Migration Checklist
- [ ] Update Parse.setup with new server URL
- [ ] Replace client key with REST API key
- [ ] Configure file adapter (S3, GCS, GridFS)
- [ ] Migrate Cloud Code to webhooks
- [ ] Update push notification settings
- [ ] Test authentication flows
- [ ] Verify ACLs and security rules

## Best Practices

### Model Design
1. Use meaningful class names (capitalized, singular)
2. Define properties explicitly for documentation
3. Add validations for data integrity
4. Use scopes for common queries
5. Implement callbacks judiciously

### Query Optimization
1. Use select to limit fields
2. Implement caching for read-heavy queries
3. Use includes for association preloading
4. Batch operations when possible
5. Add indexes via Parse Dashboard

### Security
1. Always use ACLs for sensitive data
2. Validate input on both client and server
3. Use master key only when necessary
4. Implement rate limiting
5. Audit webhook functions

### Error Handling
1. Use raise_on_save_failure in development
2. Implement proper error recovery
3. Log errors with context
4. Handle network timeouts gracefully
5. Validate before saving

## Common Patterns

### Soft Deletes
```ruby
class Article < Parse::Object
  property :deleted_at, :date
  
  scope :active, -> { query(deleted_at: nil) }
  scope :deleted, -> { query(:deleted_at.exists => true) }
  
  def soft_delete
    self.deleted_at = Time.current
    save
  end
end
```

### Versioning
```ruby
class Document < Parse::Object
  property :version, :integer, default: 1
  has_many :versions, -> { order(:version) }
  
  before_save :increment_version, if: :changed?
  
  def increment_version
    self.version += 1
  end
end
```

### Full-Text Search
```ruby
class Post < Parse::Object
  property :title
  property :content
  property :search_text
  
  before_save :update_search_text
  
  def update_search_text
    self.search_text = "#{title} #{content}".downcase
  end
  
  scope :search, ->(term) { 
    query(:search_text.like => "%#{term.downcase}%") 
  }
end
```

### Counters and Statistics
```ruby
class Article < Parse::Object
  property :view_count, :integer, default: 0
  property :like_count, :integer, default: 0
  
  def increment_views
    op(:view_count).increment
    save
  end
  
  def add_like
    op(:like_count).increment
    save
  end
end
```

## Troubleshooting

### Common Issues

1. **Field Name Mismatch**
   - Parse uses camelCase, Ruby uses snake_case
   - Solution: Ensure columnize is enabled

2. **Session Token Expired**
   - Tokens expire after inactivity
   - Solution: Implement token refresh logic

3. **ACL Permissions Denied**
   - Object ACL prevents access
   - Solution: Check ACLs or use master key

4. **Query Timeout**
   - Large datasets without indexes
   - Solution: Add indexes, use limit/skip

5. **File Upload Issues**
   - File adapter not configured
   - Solution: Configure S3/GCS adapter

### Debug Mode
```ruby
# Enable debug logging
Parse::Client.setup(logging: true, logger: Logger.new(STDOUT))

# Inspect requests
Parse::Client.log_network_requests = true

# Track query compilation
query = Song.query(title: "Test")
puts query.compile  # See actual Parse query
```

## Version Compatibility

- Ruby 2.6+ required
- Parse Server 2.5+ recommended
- Rails 5.0+ for Rails integration
- ActiveModel 5.0+ for validations

## Resources

- [GitHub Repository](https://github.com/modernistik/parse-stack)
- [Parse Server Documentation](https://docs.parseplatform.org)
- [API Reference](https://github.com/modernistik/parse-stack/wiki)
- [Migration Guide](https://parseplatform.org/parse-server/guide/)