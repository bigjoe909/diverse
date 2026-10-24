IF OBJECT_ID(N'dbo.Users', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Users
    (
        UserId uniqueidentifier NOT NULL CONSTRAINT DF_Users_UserId DEFAULT NEWID(),
        Name nvarchar(100) NOT NULL,
        Email nvarchar(254) NOT NULL,
        PasswordSalt varbinary(16) NOT NULL,
        PasswordHash varbinary(32) NOT NULL,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_Users_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_Users PRIMARY KEY (UserId),
        CONSTRAINT UQ_Users_Email UNIQUE (Email)
    );
END;

IF OBJECT_ID(N'dbo.AdminAccount', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AdminAccount
    (
        AccountId tinyint NOT NULL,
        Email nvarchar(254) NOT NULL,
        PasswordSalt varbinary(16) NOT NULL,
        PasswordHash varbinary(32) NOT NULL,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_AdminAccount_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_AdminAccount PRIMARY KEY (AccountId),
        CONSTRAINT UQ_AdminAccount_Email UNIQUE (Email),
        CONSTRAINT CK_AdminAccount_SingleOwner CHECK (AccountId = 1)
    );
END;

IF COL_LENGTH(N'dbo.Users', N'Bio') IS NULL
BEGIN
    ALTER TABLE dbo.Users ADD Bio nvarchar(500) NOT NULL CONSTRAINT DF_Users_Bio DEFAULT N'';
END;

IF COL_LENGTH(N'dbo.Users', N'Skills') IS NULL
BEGIN
    ALTER TABLE dbo.Users ADD Skills nvarchar(250) NOT NULL CONSTRAINT DF_Users_Skills DEFAULT N'';
END;

IF COL_LENGTH(N'dbo.Users', N'IsBanned') IS NULL
BEGIN
    ALTER TABLE dbo.Users ADD IsBanned bit NOT NULL CONSTRAINT DF_Users_IsBanned DEFAULT 0 WITH VALUES;
END;

IF COL_LENGTH(N'dbo.Users', N'BanReason') IS NULL
BEGIN
    ALTER TABLE dbo.Users ADD BanReason nvarchar(500) NULL;
END;

IF COL_LENGTH(N'dbo.Users', N'BannedAt') IS NULL
BEGIN
    ALTER TABLE dbo.Users ADD BannedAt datetime2(3) NULL;
END;

IF COL_LENGTH(N'dbo.Users', N'BannedBy') IS NULL
BEGIN
    ALTER TABLE dbo.Users ADD BannedBy uniqueidentifier NULL;
END;

IF OBJECT_ID(N'dbo.ProfilePictures', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ProfilePictures
    (
        UserId uniqueidentifier NOT NULL CONSTRAINT PK_ProfilePictures PRIMARY KEY,
        FileName nvarchar(255) NOT NULL,
        ContentType nvarchar(100) NOT NULL,
        FileData varbinary(max) NOT NULL,
        UpdatedAt datetime2(3) NOT NULL CONSTRAINT DF_ProfilePictures_UpdatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ProfilePictures_Users FOREIGN KEY (UserId) REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_ProfilePictures_ContentType CHECK (ContentType IN (N'image/jpeg', N'image/png', N'image/gif', N'image/webp')),
        CONSTRAINT CK_ProfilePictures_Size CHECK (DATALENGTH(FileData) BETWEEN 1 AND 5242880)
    );
END;

IF OBJECT_ID(N'dbo.UserLocations', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserLocations
    (
        UserId uniqueidentifier NOT NULL CONSTRAINT PK_UserLocations PRIMARY KEY,
        Latitude decimal(9,6) NOT NULL,
        Longitude decimal(9,6) NOT NULL,
        AccuracyMeters int NOT NULL,
        UpdatedAt datetime2(3) NOT NULL CONSTRAINT DF_UserLocations_UpdatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_UserLocations_Users FOREIGN KEY (UserId) REFERENCES dbo.Users(UserId) ON DELETE CASCADE,
        CONSTRAINT CK_UserLocations_Latitude CHECK (Latitude BETWEEN -90 AND 90),
        CONSTRAINT CK_UserLocations_Longitude CHECK (Longitude BETWEEN -180 AND 180),
        CONSTRAINT CK_UserLocations_Accuracy CHECK (AccuracyMeters BETWEEN 0 AND 100000)
    );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_UserLocations_UpdatedAt' AND object_id = OBJECT_ID(N'dbo.UserLocations'))
BEGIN
    CREATE INDEX IX_UserLocations_UpdatedAt ON dbo.UserLocations (UpdatedAt DESC);
END;

IF OBJECT_ID(N'dbo.Friendships', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Friendships
    (
        FriendshipId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Friendships PRIMARY KEY,
        RequesterId uniqueidentifier NOT NULL,
        AddresseeId uniqueidentifier NOT NULL,
        Status nvarchar(10) NOT NULL CONSTRAINT DF_Friendships_Status DEFAULT N'pending',
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_Friendships_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_Friendships_Requester FOREIGN KEY (RequesterId) REFERENCES dbo.Users(UserId),
        CONSTRAINT FK_Friendships_Addressee FOREIGN KEY (AddresseeId) REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_Friendships_DifferentUsers CHECK (RequesterId <> AddresseeId),
        CONSTRAINT CK_Friendships_Status CHECK (Status IN (N'pending', N'accepted')),
        CONSTRAINT UQ_Friendships_Pair UNIQUE (RequesterId, AddresseeId)
    );
END;

IF OBJECT_ID(N'dbo.Posts', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Posts
    (
        PostId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Posts PRIMARY KEY,
        UserId uniqueidentifier NOT NULL,
        Content nvarchar(2000) NOT NULL,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_Posts_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_Posts_Users FOREIGN KEY (UserId) REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_Posts_Content CHECK (LEN(LTRIM(RTRIM(Content))) > 0)
    );
END;

IF OBJECT_ID(N'dbo.PostMedia', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PostMedia
    (
        PostId bigint NOT NULL CONSTRAINT PK_PostMedia PRIMARY KEY,
        FileName nvarchar(255) NOT NULL,
        ContentType nvarchar(100) NOT NULL,
        FileData varbinary(max) NOT NULL,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_PostMedia_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_PostMedia_Posts FOREIGN KEY (PostId) REFERENCES dbo.Posts(PostId),
        CONSTRAINT CK_PostMedia_ContentType CHECK (ContentType IN (N'image/jpeg', N'image/png', N'image/gif', N'image/webp', N'video/mp4', N'video/webm')),
        CONSTRAINT CK_PostMedia_Size CHECK (DATALENGTH(FileData) BETWEEN 1 AND 20971520)
    );
END;

IF OBJECT_ID(N'dbo.PostLikes', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PostLikes
    (
        PostId bigint NOT NULL,
        UserId uniqueidentifier NOT NULL,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_PostLikes_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_PostLikes PRIMARY KEY (PostId, UserId),
        CONSTRAINT FK_PostLikes_Posts FOREIGN KEY (PostId) REFERENCES dbo.Posts(PostId),
        CONSTRAINT FK_PostLikes_Users FOREIGN KEY (UserId) REFERENCES dbo.Users(UserId)
    );
END;

IF OBJECT_ID(N'dbo.PostComments', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PostComments
    (
        CommentId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_PostComments PRIMARY KEY,
        PostId bigint NOT NULL,
        UserId uniqueidentifier NOT NULL,
        Content nvarchar(1000) NOT NULL,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_PostComments_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_PostComments_Posts FOREIGN KEY (PostId) REFERENCES dbo.Posts(PostId),
        CONSTRAINT FK_PostComments_Users FOREIGN KEY (UserId) REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_PostComments_Content CHECK (LEN(LTRIM(RTRIM(Content))) > 0)
    );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PostComments_PostId_CreatedAt' AND object_id = OBJECT_ID(N'dbo.PostComments'))
BEGIN
    CREATE INDEX IX_PostComments_PostId_CreatedAt ON dbo.PostComments (PostId, CreatedAt, CommentId);
END;

IF OBJECT_ID(N'dbo.Messages', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Messages
    (
        MessageId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Messages PRIMARY KEY,
        SenderId uniqueidentifier NOT NULL,
        RecipientId uniqueidentifier NOT NULL,
        Content nvarchar(2000) NOT NULL,
        IsRead bit NOT NULL CONSTRAINT DF_Messages_IsRead DEFAULT 0,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_Messages_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_Messages_Sender FOREIGN KEY (SenderId) REFERENCES dbo.Users(UserId),
        CONSTRAINT FK_Messages_Recipient FOREIGN KEY (RecipientId) REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_Messages_DifferentUsers CHECK (SenderId <> RecipientId),
        CONSTRAINT CK_Messages_Content CHECK (LEN(LTRIM(RTRIM(Content))) > 0)
    );
END;

IF COL_LENGTH(N'dbo.Messages', N'IsRead') IS NULL
BEGIN
    ALTER TABLE dbo.Messages ADD IsRead bit NOT NULL CONSTRAINT DF_Messages_IsRead_Migration DEFAULT 0 WITH VALUES;
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Messages_Recipient_Read' AND object_id = OBJECT_ID(N'dbo.Messages'))
BEGIN
    CREATE INDEX IX_Messages_Recipient_Read ON dbo.Messages (RecipientId, IsRead, MessageId DESC);
END;

IF OBJECT_ID(N'dbo.Documents', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Documents
    (
        DocumentId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Documents PRIMARY KEY,
        UserId uniqueidentifier NOT NULL,
        FileName nvarchar(255) NOT NULL,
        FileData varbinary(max) NOT NULL,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_Documents_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_Documents_Users FOREIGN KEY (UserId) REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_Documents_Size CHECK (DATALENGTH(FileData) BETWEEN 1 AND 10485760)
    );
END;

IF OBJECT_ID(N'dbo.MarketplaceListings', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MarketplaceListings
    (
        ListingId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_MarketplaceListings PRIMARY KEY,
        UserId uniqueidentifier NOT NULL,
        Category nvarchar(20) NOT NULL,
        Title nvarchar(120) NOT NULL,
        Description nvarchar(1000) NOT NULL,
        Price decimal(12,2) NULL,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_MarketplaceListings_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_MarketplaceListings_Users FOREIGN KEY (UserId) REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_MarketplaceListings_Category CHECK (Category IN (N'business', N'job', N'skill', N'product')),
        CONSTRAINT CK_MarketplaceListings_Price CHECK (Price IS NULL OR Price >= 0)
    );
END;

IF OBJECT_ID(N'dbo.MarketplaceMedia', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MarketplaceMedia
    (
        ListingId bigint NOT NULL CONSTRAINT PK_MarketplaceMedia PRIMARY KEY,
        FileName nvarchar(255) NOT NULL,
        ContentType nvarchar(100) NOT NULL,
        FileData varbinary(max) NOT NULL,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_MarketplaceMedia_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_MarketplaceMedia_Listings FOREIGN KEY (ListingId) REFERENCES dbo.MarketplaceListings(ListingId),
        CONSTRAINT CK_MarketplaceMedia_ContentType CHECK (ContentType IN (N'image/jpeg', N'image/png', N'image/gif', N'image/webp', N'video/mp4', N'video/webm')),
        CONSTRAINT CK_MarketplaceMedia_Size CHECK (DATALENGTH(FileData) BETWEEN 1 AND 20971520)
    );
END;

IF OBJECT_ID(N'dbo.GameRooms', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.GameRooms
    (
        GameRoomId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_GameRooms PRIMARY KEY,
        RoomCode varchar(6) NOT NULL,
        GameType nvarchar(12) NOT NULL,
        HostId uniqueidentifier NOT NULL,
        GuestId uniqueidentifier NULL,
        Status nvarchar(10) NOT NULL CONSTRAINT DF_GameRooms_Status DEFAULT N'waiting',
        StateJson nvarchar(max) NOT NULL,
        Revision int NOT NULL CONSTRAINT DF_GameRooms_Revision DEFAULT 1,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_GameRooms_CreatedAt DEFAULT SYSUTCDATETIME(),
        UpdatedAt datetime2(3) NOT NULL CONSTRAINT DF_GameRooms_UpdatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT UQ_GameRooms_RoomCode UNIQUE (RoomCode),
        CONSTRAINT FK_GameRooms_Host FOREIGN KEY (HostId) REFERENCES dbo.Users(UserId),
        CONSTRAINT FK_GameRooms_Guest FOREIGN KEY (GuestId) REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_GameRooms_GameType CHECK (GameType IN (N'chess', N'snooker', N'ludo', N'whot')),
        CONSTRAINT CK_GameRooms_Status CHECK (Status IN (N'waiting', N'active', N'finished')),
        CONSTRAINT CK_GameRooms_DifferentPlayers CHECK (GuestId IS NULL OR GuestId <> HostId),
        CONSTRAINT CK_GameRooms_StateJson CHECK (ISJSON(StateJson) = 1)
    );
END;

IF OBJECT_ID(N'dbo.Movies', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Movies
    (
        MovieId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Movies PRIMARY KEY,
        UserId uniqueidentifier NOT NULL,
        Title nvarchar(120) NOT NULL,
        Description nvarchar(1000) NOT NULL,
        FileName nvarchar(255) NOT NULL,
        ContentType nvarchar(100) NOT NULL,
        FileSize bigint NOT NULL,
        ChunkCount int NOT NULL,
        RightsConfirmed bit NOT NULL,
        IsComplete bit NOT NULL CONSTRAINT DF_Movies_IsComplete DEFAULT 0,
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_Movies_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_Movies_Users FOREIGN KEY (UserId) REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_Movies_ContentType CHECK (ContentType IN (N'video/mp4', N'video/webm')),
        CONSTRAINT CK_Movies_FileSize CHECK (FileSize BETWEEN 1 AND 1073741824),
        CONSTRAINT CK_Movies_ChunkCount CHECK (ChunkCount BETWEEN 1 AND 1024),
        CONSTRAINT CK_Movies_RightsConfirmed CHECK (RightsConfirmed = 1)
    );
END;

IF OBJECT_ID(N'dbo.MovieChunks', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MovieChunks
    (
        MovieId bigint NOT NULL,
        ChunkIndex int NOT NULL,
        FileData varbinary(max) NOT NULL,
        CONSTRAINT PK_MovieChunks PRIMARY KEY (MovieId, ChunkIndex),
        CONSTRAINT FK_MovieChunks_Movies FOREIGN KEY (MovieId) REFERENCES dbo.Movies(MovieId) ON DELETE CASCADE,
        CONSTRAINT CK_MovieChunks_Index CHECK (ChunkIndex BETWEEN 0 AND 1023),
        CONSTRAINT CK_MovieChunks_Size CHECK (DATALENGTH(FileData) BETWEEN 1 AND 1048576)
    );
END;

IF OBJECT_ID(N'dbo.UserReports', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserReports
    (
        ReportId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_UserReports PRIMARY KEY,
        ReporterId uniqueidentifier NOT NULL,
        ReportedUserId uniqueidentifier NOT NULL,
        Category nvarchar(24) NOT NULL,
        Details nvarchar(1200) NOT NULL,
        Status nvarchar(12) NOT NULL CONSTRAINT DF_UserReports_Status DEFAULT N'open',
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_UserReports_CreatedAt DEFAULT SYSUTCDATETIME(),
        ReviewedAt datetime2(3) NULL,
        ReviewedBy uniqueidentifier NULL,
        CONSTRAINT FK_UserReports_Reporter FOREIGN KEY (ReporterId) REFERENCES dbo.Users(UserId),
        CONSTRAINT FK_UserReports_Reported FOREIGN KEY (ReportedUserId) REFERENCES dbo.Users(UserId),
        CONSTRAINT FK_UserReports_Reviewer FOREIGN KEY (ReviewedBy) REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_UserReports_DifferentUsers CHECK (ReporterId <> ReportedUserId),
        CONSTRAINT CK_UserReports_Category CHECK (Category IN (N'scam', N'fraud', N'impersonation', N'harassment', N'other')),
        CONSTRAINT CK_UserReports_Status CHECK (Status IN (N'open', N'resolved'))
    );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_UserReports_Status_CreatedAt' AND object_id = OBJECT_ID(N'dbo.UserReports'))
BEGIN
    CREATE INDEX IX_UserReports_Status_CreatedAt ON dbo.UserReports (Status, CreatedAt DESC);
END;

IF OBJECT_ID(N'dbo.UnbanAppeals', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.UnbanAppeals
    (
        AppealId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_UnbanAppeals PRIMARY KEY,
        UserId uniqueidentifier NOT NULL,
        Reason nvarchar(2000) NOT NULL,
        Status nvarchar(12) NOT NULL CONSTRAINT DF_UnbanAppeals_Status DEFAULT N'pending',
        CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_UnbanAppeals_CreatedAt DEFAULT SYSUTCDATETIME(),
        ReviewedAt datetime2(3) NULL,
        ReviewedBy uniqueidentifier NULL,
        CONSTRAINT FK_UnbanAppeals_User FOREIGN KEY (UserId) REFERENCES dbo.Users(UserId),
        CONSTRAINT FK_UnbanAppeals_Reviewer FOREIGN KEY (ReviewedBy) REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_UnbanAppeals_Status CHECK (Status IN (N'pending', N'approved', N'denied')),
        CONSTRAINT CK_UnbanAppeals_Reason CHECK (LEN(LTRIM(RTRIM(Reason))) BETWEEN 20 AND 2000)
    );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_UnbanAppeals_OnePending' AND object_id = OBJECT_ID(N'dbo.UnbanAppeals'))
BEGIN
    CREATE UNIQUE INDEX UX_UnbanAppeals_OnePending ON dbo.UnbanAppeals (UserId) WHERE Status = N'pending';
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_GameRooms_Status_UpdatedAt' AND object_id = OBJECT_ID(N'dbo.GameRooms'))
BEGIN
    CREATE INDEX IX_GameRooms_Status_UpdatedAt ON dbo.GameRooms (Status, UpdatedAt DESC);
END;
