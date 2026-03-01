//! Context plugin middleware system with dependency injection.
//!
//! This module defines the plugin trait interface and registry system for
//! context plugins, replacing the previous script execution approach with
//! a more type-safe and performant middleware pattern.

use crate::config::Config;
use std::collections::HashMap;
use std::path::Path;

/// Plugin context containing shared dependencies that plugins need.
#[allow(dead_code)]
pub struct PluginContext<'a> {
    /// Root directory of the agent
    pub root: &'a Path,
    /// Loaded configuration
    pub config: &'a Config,
    /// Current iteration number
    pub iteration: usize,
    /// Additional plugin-specific data
    pub data: HashMap<String, String>,
}

/// Plugin metadata describing the plugin's purpose and behavior.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct PluginMeta {
    /// Plugin name (used for ordering and identification)
    pub name: String,
    /// Human-readable description
    pub description: String,
    /// Plugin version
    pub version: String,
    /// Whether the plugin's output should be treated as external/untrusted
    pub is_external: bool,
    /// Plugin priority (lower numbers run first)
    pub priority: i32,
}

/// Result of plugin execution containing content and metadata.
#[allow(dead_code)]
pub struct PluginResult {
    /// Generated content (markdown)
    pub content: String,
    /// Security warnings if any suspicious patterns detected
    pub warnings: Vec<String>,
    /// Optional metadata for logging/debugging
    pub metadata: HashMap<String, String>,
}

/// Error types for plugin operations.
#[derive(Debug, thiserror::Error)]
#[allow(dead_code)]
pub enum PluginError {
    #[error("Plugin initialization failed: {0}")]
    InitializationFailed(String),
    #[error("Plugin execution failed: {0}")]
    ExecutionFailed(String),
    #[error("Plugin dependency not found: {0}")]
    DependencyNotFound(String),
    #[error("Plugin configuration invalid: {0}")]
    InvalidConfiguration(String),
}

/// Core plugin trait that all context plugins must implement.
pub trait ContextPlugin: Send + Sync {
    /// Get plugin metadata
    fn meta(&self) -> &PluginMeta;

    /// Initialize the plugin with context (called once at startup)
    fn initialize(&mut self, _context: &PluginContext) -> Result<(), PluginError> {
        // Default implementation does nothing
        Ok(())
    }

    /// Execute the plugin and generate context content
    fn execute(&self, context: &PluginContext) -> Result<PluginResult, PluginError>;

    /// Cleanup resources (called at shutdown)
    #[allow(dead_code)]
    fn cleanup(&mut self) -> Result<(), PluginError> {
        // Default implementation does nothing
        Ok(())
    }

    /// Check if plugin should run (allows conditional execution)
    fn should_run(&self, _context: &PluginContext) -> bool {
        // Default implementation always runs
        true
    }
}

/// Registry for managing and executing context plugins.
pub struct PluginRegistry {
    plugins: Vec<Box<dyn ContextPlugin>>,
    initialized: bool,
}

impl PluginRegistry {
    /// Create a new empty plugin registry
    pub fn new() -> Self {
        Self {
            plugins: Vec::new(),
            initialized: false,
        }
    }

    /// Register a plugin
    pub fn register(&mut self, plugin: Box<dyn ContextPlugin>) {
        self.plugins.push(plugin);
    }

    /// Initialize all plugins with context
    pub fn initialize(&mut self, context: &PluginContext) -> Result<(), PluginError> {
        if self.initialized {
            return Ok(());
        }

        // Sort plugins by priority
        self.plugins.sort_by_key(|p| p.meta().priority);

        // Initialize each plugin
        for plugin in &mut self.plugins {
            plugin.initialize(context)?;
        }

        self.initialized = true;
        Ok(())
    }

    /// Execute all plugins and collect their outputs
    pub fn execute_all(
        &self,
        context: &PluginContext,
    ) -> Result<Vec<(String, PluginResult)>, PluginError> {
        if !self.initialized {
            return Err(PluginError::InitializationFailed(
                "Registry not initialized".to_string(),
            ));
        }

        let mut results = Vec::new();

        for plugin in &self.plugins {
            if plugin.should_run(context) {
                let result = plugin.execute(context)?;
                results.push((plugin.meta().name.clone(), result));
            }
        }

        Ok(results)
    }

    /// Cleanup all plugins
    #[allow(dead_code)]
    pub fn cleanup(&mut self) -> Result<(), PluginError> {
        for plugin in &mut self.plugins {
            plugin.cleanup()?;
        }
        self.initialized = false;
        Ok(())
    }

    /// Get list of registered plugin names
    #[allow(dead_code)]
    pub fn plugin_names(&self) -> Vec<&str> {
        self.plugins
            .iter()
            .map(|p| p.meta().name.as_str())
            .collect()
    }
}

impl Default for PluginRegistry {
    fn default() -> Self {
        Self::new()
    }
}

/// Builder for creating PluginMeta instances
pub struct PluginMetaBuilder {
    name: String,
    description: String,
    version: String,
    is_external: bool,
    priority: i32,
}

impl PluginMetaBuilder {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            description: "".to_string(),
            version: "1.0.0".to_string(),
            is_external: false,
            priority: 100,
        }
    }

    pub fn description(mut self, desc: impl Into<String>) -> Self {
        self.description = desc.into();
        self
    }

    pub fn version(mut self, ver: impl Into<String>) -> Self {
        self.version = ver.into();
        self
    }

    pub fn external(mut self, external: bool) -> Self {
        self.is_external = external;
        self
    }

    pub fn priority(mut self, prio: i32) -> Self {
        self.priority = prio;
        self
    }

    pub fn build(self) -> PluginMeta {
        PluginMeta {
            name: self.name,
            description: self.description,
            version: self.version,
            is_external: self.is_external,
            priority: self.priority,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config;
    use crate::runner;
    use std::collections::HashMap;

    struct TestPlugin {
        meta: PluginMeta,
        initialized: bool,
    }

    impl TestPlugin {
        fn new(name: &str) -> Self {
            Self {
                meta: PluginMetaBuilder::new(name)
                    .description("Test plugin")
                    .priority(50)
                    .build(),
                initialized: false,
            }
        }
    }

    impl ContextPlugin for TestPlugin {
        fn meta(&self) -> &PluginMeta {
            &self.meta
        }

        fn initialize(&mut self, _context: &PluginContext) -> Result<(), PluginError> {
            self.initialized = true;
            Ok(())
        }

        fn execute(&self, _context: &PluginContext) -> Result<PluginResult, PluginError> {
            Ok(PluginResult {
                content: format!("Output from {}", self.meta.name),
                warnings: vec![],
                metadata: HashMap::new(),
            })
        }

        fn should_run(&self, _context: &PluginContext) -> bool {
            self.initialized
        }
    }

    #[test]
    fn test_plugin_registry() {
        let mut registry = PluginRegistry::new();
        let plugin = Box::new(TestPlugin::new("test"));

        registry.register(plugin);
        assert_eq!(registry.plugin_names(), vec!["test"]);
    }

    #[test]
    fn test_plugin_execution() {
        let dir = tempfile::tempdir().unwrap();
        runner::init(dir.path(), "test-agent").unwrap();
        let cfg = config::load(dir.path()).unwrap();

        let mut registry = PluginRegistry::new();
        let plugin = Box::new(TestPlugin::new("test"));

        registry.register(plugin);

        let context = PluginContext {
            root: dir.path(),
            config: &cfg,
            iteration: 1,
            data: HashMap::new(),
        };

        registry.initialize(&context).unwrap();
        let results = registry.execute_all(&context).unwrap();

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0, "test");
        assert!(results[0].1.content.contains("Output from test"));
    }

    #[test]
    fn test_plugin_meta_builder() {
        let meta = PluginMetaBuilder::new("example")
            .description("An example plugin")
            .version("2.0.0")
            .external(true)
            .priority(25)
            .build();

        assert_eq!(meta.name, "example");
        assert_eq!(meta.description, "An example plugin");
        assert_eq!(meta.version, "2.0.0");
        assert_eq!(meta.is_external, true);
        assert_eq!(meta.priority, 25);
    }
}
