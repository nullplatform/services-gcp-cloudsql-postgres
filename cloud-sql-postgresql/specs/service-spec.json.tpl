{
  "name": "GCP Cloud SQL PostgreSQL",
  "slug": "gcp-cloud-sql-postgresql",
  "type": "dependency",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "available_links": ["database-user"],
  "selectors": {
    "category": "Database",
    "imported": false,
    "provider": "GCP",
    "sub_category": "Relational Database"
  },
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": ["database_name"],
      "uiSchema": {
        "type": "VerticalLayout",
        "elements": [
          {
            "type": "Control",
            "label": "Database Name",
            "scope": "#/properties/database_name"
          },
          {
            "type": "Control",
            "label": "PostgreSQL Version",
            "scope": "#/properties/postgres_version",
            "options": { "format": "radio" }
          },
          {
            "type": "Control",
            "label": "Machine Tier",
            "scope": "#/properties/tier"
          },
          {
            "type": "Control",
            "label": "Disk Size (GB)",
            "scope": "#/properties/disk_size_gb"
          },
          {
            "type": "Categorization",
            "options": {
              "collapsable": { "label": "ADVANCED", "collapsed": true }
            },
            "elements": [
              {
                "type": "Category",
                "label": "Resilience",
                "elements": [
                  {
                    "type": "Control",
                    "label": "Backups Retained",
                    "scope": "#/properties/backup_retention_days"
                  },
                  {
                    "type": "Control",
                    "label": "Regional High Availability",
                    "scope": "#/properties/high_availability"
                  }
                ]
              }
            ]
          },
          {
            "type": "Control",
            "label": "Hostname",
            "scope": "#/properties/hostname"
          },
          {
            "type": "Control",
            "label": "Port",
            "scope": "#/properties/port"
          }
        ]
      },
      "properties": {
        "database_name": {
          "type": "string",
          "title": "Database Name",
          "export": true,
          "description": "Database created on the instance. Lowercase letters, digits and underscores, starting with a letter. Up to 63 characters.",
          "pattern": "^[a-z][a-z0-9_]{0,62}$",
          "editableOn": ["create"],
          "order": 1
        },
        "postgres_version": {
          "type": "string",
          "title": "PostgreSQL Version",
          "default": "16",
          "enum": ["15", "16", "17"],
          "description": "Major version. Cannot be changed after creation: an in-place major upgrade is a Cloud SQL operation outside this service.",
          "editableOn": ["create"],
          "order": 2
        },
        "tier": {
          "type": "string",
          "title": "Machine Tier",
          "default": "db-g1-small",
          "enum": ["db-f1-micro", "db-g1-small", "db-custom-1-3840", "db-custom-2-7680", "db-custom-4-16384"],
          "description": "db-f1-micro and db-g1-small are shared-core tiers for development, with no SLA and no high availability. db-custom-<vCPUs>-<memory MB> tiers are dedicated and suit production load.",
          "editableOn": ["create", "update"],
          "order": 3
        },
        "disk_size_gb": {
          "type": "integer",
          "title": "Disk Size (GB)",
          "default": 10,
          "minimum": 10,
          "maximum": 1024,
          "description": "SSD size. It can grow on update but never shrink: Cloud SQL does not support reducing a disk.",
          "editableOn": ["create", "update"],
          "order": 4
        },
        "backup_retention_days": {
          "type": "integer",
          "title": "Backups Retained",
          "default": 7,
          "minimum": 1,
          "maximum": 365,
          "description": "Number of daily automated backups Cloud SQL keeps, so roughly the days you can restore from.",
          "editableOn": ["create", "update"],
          "order": 5
        },
        "high_availability": {
          "type": "boolean",
          "title": "Regional High Availability",
          "default": false,
          "description": "Keeps a standby in another zone of the region and turns on point-in-time recovery. Doubles the compute cost and is ignored on shared-core tiers, which do not support it.",
          "editableOn": ["create", "update"],
          "order": 6
        },
        "hostname": {
          "type": "string",
          "title": "Hostname",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Private IP address of the instance (auto-populated after creation)",
          "order": 7
        },
        "port": {
          "type": "number",
          "title": "Port",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "PostgreSQL port (auto-populated after creation)",
          "order": 8
        },
        "instance_name": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "Internal: Cloud SQL instance name. Computed once on first create and read back on every later action so a rename never forces a replacement."
        },
        "connection_name": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "Internal: instance connection name (<project>:<region>:<instance>)"
        },
        "project_id": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "Internal: GCP project holding the instance"
        }
      }
    },
    "values": {}
  }
}
