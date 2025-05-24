# NRI Framework in Zig

## Overview
The NRI Framework is a graphics framework designed to facilitate the development of high-performance graphics applications. It provides a set of tools and utilities for rendering, resource management, and user input handling.

## Features
- **Graphics API Initialization**: Simplifies the setup of various graphics APIs.
- **Rendering**: Provides functions for rendering 2D and 3D graphics.
- **Resource Management**: Manages textures, buffers, and other graphics resources efficiently.
- **User Input Handling**: Supports keyboard and mouse input for interactive applications.
- **Timing Utilities**: Helps manage frame rates and measure elapsed time.

## Project Structure
```
zig-nriframework
├── src
│   ├── main.zig          # Entry point of the application
│   ├── nriframework.zig  # Core functionality of the NRI framework
│   ├── camera.zig        # Camera operations and transformations
│   ├── controls.zig      # User input management
│   ├── helper.zig        # Utility functions for various tasks
│   ├── timer.zig         # Timing utilities
│   ├── utils.zig         # Miscellaneous utility functions
│   └── types
│       └── index.zig     # Common types and constants
├── build.zig             # Build configuration for the Zig project
└── README.md             # Documentation for the project
```

## Setup Instructions
1. Ensure you have the Zig compiler installed. You can download it from [ziglang.org](https://ziglang.org/download/).
2. Clone the repository:
   ```
   git clone <repository-url>
   cd zig-nriframework
   ```
3. Build the project:
   ```
   zig build
   ```

## Usage
To run the application, execute the following command:
```
zig run src/main.zig
```

## Contributing
Contributions are welcome! Please submit a pull request or open an issue for any enhancements or bug fixes.

## License
This project is licensed under the MIT License. See the LICENSE file for more details.