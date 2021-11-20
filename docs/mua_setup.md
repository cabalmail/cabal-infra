# Configuring Mail User Agents
Email clients differ, but the basic settings are these (substituting your control domain for `example.net`):

## Incoming Settings
|Setting |Value                   |
|--------|------------------------|
|Type    |IMAP                    |
|Port    |993                     |
|SSL     |Yes                     |
|Login   |Plain                   |
|Server  |imap.example.net        |
|Username|As entered during signup|
|Password|As entered during signup|

## Outgoing Settings
|Setting  |Value                  |
|---------|-----------------------|
|Type     |SMTP or SMTPS          |
|Port     |465                    |
|SSL      |Yes                    |
|StartTLS |No                     |
|Login    |Plain                  |
|Server   |smtp-out.example.net   |
|Username|As entered during signup|
|Password|As entered during signup|
