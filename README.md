# HelloID-Conn-Prov-Target-Simac-Pronto

> [!IMPORTANT]
> This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.

<p align="center">
  <img src="https://www.simac.com/frontend/img/simac-logo.png">
</p>

## Table of contents

- [HelloID-Conn-Prov-Target-Simac-Pronto](#helloid-conn-prov-target-simac-pronto)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Supported features](#supported-features)
  - [Getting started](#getting-started)
    - [HelloID Icon URL](#helloid-icon-url)
    - [Requirements](#requirements)
      - [Concurrent Sessions](#concurrent-sessions)
      - [Identification Numbers](#identification-numbers)
      - [ExternalId property](#externalid-property)
    - [Connection settings](#connection-settings)
    - [Correlation configuration](#correlation-configuration)
    - [Field mapping](#field-mapping)
    - [Account Reference](#account-reference)
  - [Remarks](#remarks)
    - [ID field can be empty](#id-field-can-be-empty)
    - [Enable/Disable accounts](#enabledisable-accounts)
    - [Disabled accounts](#disabled-accounts)
    - [Permissions](#permissions)
      - [Identifications permissions](#identifications-permissions)
    - [Reboarding](#reboarding)
    - [Under construction](#under-construction)
      - [PreferedFullname](#preferedfullname)
  - [Development resources](#development-resources)
    - [API endpoints](#api-endpoints)
    - [API documentation](#api-documentation)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction

_HelloID-Conn-Prov-Target-Simac-Pronto_ is a _target_ connector. _Simac-Pronto_ provides a set of REST APIs that allow you to programmatically interact with its data.

## Supported features

The following features are available:

| Feature                                   | Supported | Actions                                 | Remarks            |
| ----------------------------------------- | --------- | --------------------------------------- | ------------------ |
| **Account Lifecycle**                     | ✅         | Create, Update, Enable, Disable, Delete |                    |
| **Permissions**                           | ✅         | Retrieve, Grant, Revoke                 | Identifications and PersonsGroups |
| **Resources**                             | ❌         | -                                       |                    |
| **Entitlement Import: Accounts**          | ✅         | -                                       |                    |
| **Entitlement Import: Permissions**       | ✅         | Identifications and PersonsGroups                                       |                    |
| **Governance Reconciliation Resolutions** | ✅         | -                                       |                    |

## Getting started

### HelloID Icon URL
URL of the icon used for the HelloID Provisioning target system.
```
https://raw.githubusercontent.com/Tools4everBV/HelloID-Conn-Prov-Target-Simac-Pronto/refs/heads/main/Icon.png
```

### Requirements

#### Concurrent Sessions
- **Sequential Operations**: The grant and revoke permissions script use the Patch operation on a person. This means that concurrent actions should be set to 1 to ensure all permissions are correctly set.

#### Identification Numbers
- The connector is created with the assumption that the identification numbers (pass numbers) are stored in HR and therefore in the HelloID Person object. These numbers are used to grant the identification permissions in Simac Pronto. [Remarks - Identification permissions](#identifications-permissions)

#### ExternalId property
- The `ExternalId` in Simac-Pronto is used to correlate the HelloID Person to the Simac-Pronto account. Therefore, this property must be populated with the internal ID of the person in Simac-Pronto. [Remarks - ID field can be empty](#id-field-can-be-empty)

### Connection settings

The following settings are required to connect to the API.

| Setting  | Description                        | Mandatory |
| -------- | ---------------------------------- | --------- |
| UserName | The UserName to connect to the API | Yes       |
| Password | The Password to connect to the API | Yes       |
| BaseUrl  | The URL to the API                 | Yes       |

### Correlation configuration

The correlation configuration is used to specify which properties will be used to match an existing account within _Simac-Pronto_ to a person in _HelloID_.

| Setting                   | Value                             |
| ------------------------- | --------------------------------- |
| Enable correlation        | `True`                            |
| Person correlation field  | `PersonContext.Person.ExternalId` |
| Account correlation field | `Id`                              |

> [!TIP]
> _For more information on correlation, please refer to our correlation [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems/correlation.html) pages_.

### Field mapping

The field mapping can be imported by using the _fieldMapping.json_ file.

### Account Reference

The account reference is populated with the `Id` property from _Simac-Pronto_

## Remarks
### ID field can be empty
The `ID` field of a `Person` and the `PersonGroup` can be empty. In the UI, there is a field called externalID. The value of the externalID is returned in the ID field in the API. However, the externalID cannot be retrieved via the API. Additionally, the internal ID itself is not available.

> Requirement: To be able to correlate the existing Simac Pronto persons or groups, the `externalID` must be populated by the customer/vendor with the "internal" ID.

### Enable/Disable accounts
The enable and disable actions have some additional considerations that you need to be aware of when implementing the business rules. When an account is disabled or enabled, the granted permissions are affected: disabling and enabling an account revokes the permissions. This behavior from the API is not desirable; therefore, the `enable` and `disable` scripts always include all current permissions in the API request.

### Disabled accounts
- **Not visible in the UI**: Disabled accounts are not visible in the UI, likely because they are not linked to a person group.

### Permissions

#### Identifications permissions
The identification permissions of a Simac account are basically the physical passes a person has. The connector is created assuming that the pass numbers of a person are saved in HR and therefore stored in the HelloID Person. These numbers can therefore be used directly to grant the identification permissions in Simac Pronto, without the need for additional lookups.

- **Dynamic permissions**: The identification permissions use dynamic permissions to grant and revoke the passes.
- **One Identifications permission**: The connector is now built to grant one identification permission per person. To ensure this, we only consider the primary contract when determining which permission should be granted. Granting more than one permission is possible, but this requires changes to the connector.

- **SimacProntoPassNumber**: The `Identifications` dynamic permissions are currently based on `Custom.SimacProntoPassNumber`:
 ```Powershell
# Script Mapping lookup values
$identificationId  = $personContext.Person.Custom.SimacProntoPassNumber # Mandatory
 ```
 - **No update permission**: Because this connector is currently built to grant only one identification permission, it is not necessary to update the identification (sub)permission itself. If the property that correlates to the identification changes, the connector uses a grant-and-revoke approach to correctly update the permission. The update operation can still be triggered, so a “no change” audit log has been implemented.

 - **Configure Import Script**: Must be the same as the values used in retrieve /static permissions.
 ```Powershell
  # Configure, must be the same as the values used in retrieve permissions
  $permissionReference = 'Identifications'
  $permissionDisplayName = 'Identifications'
```

### Reboarding
The delete action of the connector does not perform a hard delete of the person in Simac Pronto. Instead, it disables the person. Normally, this could cause uniqueness issues—for example, with email addresses—when reboarding a person. However, Simac Pronto has no uniqueness constraints on these fields, so reboarding itself is not an issue. The possible drawback is that multiple accounts may exist in Pronto with the same email address.

### Under construction
#### PreferedFullname
- **PreferedFullname**: There is a typo in the API property `PreferedFullname`. The connector uses this property directly, and therefore the same typo exists in the field mapping.


## Development resources

### API endpoints

The following endpoints are used by the connector

| Endpoint                | HTTP Method        | Description                                    |
| ----------------------- | ------------------ | ---------------------------------------------- |
| /api/v1/auth/token      | POST               | Retrieve authentication token                  |
| /api/v1/persons         | GET, POST          | Retrieve and Create person information         |
| /api/v1/persons/{id}    | GET, PATCH, DELETE | Retrieve, Update and Delete person information |
| /api/v1/personsgroups   | GET                | Retrieve persons groups (permissions)          |
| /api/v1/identifications | GET                | Retrieve identifications (permissions)         |

### API documentation

[Link to swagger documentation](https://demo.simacpronto.com/api/v1/docs)

## Getting help

> [!TIP]
> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems.html) pages_.

> [!TIP]
>  _If you need help, feel free to ask questions on our [forum](https://forum.helloid.com)_.

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/
