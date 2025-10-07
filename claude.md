# Claude Development Guide

## Project Knowledge
For comprehensive information about the Parse Stack functionality, architecture, and usage patterns, refer to:

**[project_knowledge.md](./project_knowledge.md)**

This document contains detailed information about:
- Complete Parse Stack architecture and components
- All Ruby classes and modules with their functionality
- API endpoints and server communication patterns
- Authentication and user management features
- Query system and data operations
- Model definitions and associations
- Configuration options and best practices
- Code examples and usage patterns

## Quick Reference

### Key Files
- `lib/parse-stack.rb` - Main entry point
- `lib/parse/stack.rb` - Core module definition
- `lib/parse/model/object.rb` - Base Parse object class
- `lib/parse/client.rb` - HTTP client and API communication
- `lib/parse/query.rb` - Query interface and operations

### Core Concepts
- **Parse::Object**: Base class for all Parse models
- **Properties**: Dynamic typed attributes with conversion
- **Queries**: DataMapper-inspired query interface
- **Associations**: belongs_to, has_one, has_many relationships
- **Client**: Low-level API communication layer

### Common Tasks

#### Create a Model
```ruby
class Song < Parse::Object
  property :title, :string, required: true
  property :artist, :string
  property :duration, :integer
  belongs_to :album
  has_many :comments
end
```

#### Query Data
```ruby
songs = Song.query(artist: "Artist Name").limit(10)
popular = Song.query(:plays.gt => 1000).order(:plays.desc)
```

#### CRUD Operations
```ruby
# Create
song = Song.create(title: "New Song", artist: "Artist")

# Read
song = Song.find("objectId")

# Update
song.title = "Updated Title"
song.save

# Delete
song.destroy
```

For detailed documentation, examples, and advanced usage patterns, see [project_knowledge.md](./project_knowledge.md).