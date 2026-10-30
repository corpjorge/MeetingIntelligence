import Foundation
import GRDB

extension AppDatabase {
    /// Schema history. Never edit a shipped migration: append a new one.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Detects schema drift during development: the database is wiped when a
        // migration's definition changes. Never active in release builds.
        if ProcessInfo.processInfo.environment["MI_ERASE_ON_SCHEMA_CHANGE"] == "1" {
            migrator.eraseDatabaseOnSchemaChange = true
        }
        #endif

        migrator.registerMigration("v1-core") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("startedAt", .datetime)
                t.column("endedAt", .datetime)
                t.column("durationSeconds", .double).notNull().defaults(to: 0)
                t.column("origin", .text).notNull()
                t.column("captureScope", .text).notNull()
                t.column("status", .text).notNull()
                t.column("language", .text).notNull().defaults(to: "es-CO")
                t.column("notes", .text)
                t.column("lastError", .text)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "meeting_on_createdAt", on: "meeting", columns: ["createdAt"])

            try db.create(table: "audioTrack") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("source", .text).notNull()
                t.column("relativePath", .text).notNull()
                t.column("originalFileName", .text)
                t.column("sampleRate", .double).notNull()
                t.column("channelCount", .integer).notNull()
                t.column("durationSeconds", .double).notNull()
                t.column("timelineOffsetSeconds", .double).notNull().defaults(to: 0)
                t.column("deviceName", .text)
                t.column("captureDetail", .text)
                t.column("fileSizeBytes", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "transcript") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.belongsTo("track", inTable: "audioTrack", onDelete: .cascade).notNull()
                t.column("engine", .text).notNull()
                t.column("modelIdentifier", .text).notNull()
                t.column("language", .text).notNull()
                t.column("isFinal", .boolean).notNull()
                t.column("audioDurationSeconds", .double).notNull()
                t.column("processingSeconds", .double).notNull()
                t.column("meanConfidence", .double)
                t.column("createdAt", .datetime).notNull()
                t.column("supersededAt", .datetime)
            }

            try db.create(table: "participant") { t in
                t.primaryKey("id", .text)
                t.column("displayName", .text).notNull()
                t.column("email", .text)
                t.column("role", .text)
                t.column("notes", .text)
                t.column("isLocalUser", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "meetingSpeaker") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("source", .text).notNull()
                t.column("clusterKey", .text).notNull()
                t.column("ordinal", .integer).notNull()
                t.column("totalSpeechSeconds", .double).notNull()
                t.column("embeddingCiphertext", .blob)
                t.column("embeddingModel", .text)
                t.belongsTo("participant", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["meetingId", "source", "clusterKey"])
            }

            try db.create(table: "transcriptSegment") { t in
                t.primaryKey("id", .text)
                t.belongsTo("transcript", onDelete: .cascade).notNull()
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.belongsTo("track", inTable: "audioTrack", onDelete: .cascade).notNull()
                t.column("source", .text).notNull()
                t.column("orderIndex", .integer).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("asrText", .text).notNull()
                t.column("vocabularyText", .text)
                t.column("editedText", .text)
                t.column("editedAt", .datetime)
                t.column("asrConfidence", .double)
                t.column("wordsJSON", .blob)
                t.belongsTo("meetingSpeaker", onDelete: .setNull)
                t.belongsTo("diarizedSpeaker", inTable: "meetingSpeaker", onDelete: .setNull)
                t.belongsTo("participant", onDelete: .setNull)
                t.column("speakerConfidence", .double)
                t.column("attribution", .text).notNull()
            }
            try db.create(index: "transcriptSegment_on_meeting_time", on: "transcriptSegment",
                          columns: ["meetingId", "startTime"])

            // Accent-insensitive full-text index kept in sync by triggers.
            try db.create(virtualTable: "transcriptSegmentFts", using: FTS5()) { t in
                t.synchronize(withTable: "transcriptSegment")
                t.tokenizer = .unicode61()
                t.column("asrText")
                t.column("vocabularyText")
                t.column("editedText")
            }

            try db.create(table: "speakerProfile") { t in
                t.primaryKey("id", .text)
                t.belongsTo("participant", onDelete: .cascade).notNull().unique()
                t.column("consentStatement", .text).notNull()
                t.column("consentRecordedAt", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("retentionDays", .integer)
                t.column("lastMatchedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "voiceSample") { t in
                t.primaryKey("id", .text)
                t.belongsTo("profile", inTable: "speakerProfile", onDelete: .cascade).notNull()
                t.column("origin", .text).notNull()
                t.belongsTo("meeting", onDelete: .setNull)
                t.column("startTime", .double)
                t.column("endTime", .double)
                t.column("durationSeconds", .double).notNull()
                t.column("embeddingCiphertext", .blob).notNull()
                t.column("embeddingModel", .text).notNull()
                t.column("validatedAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "speakerAssignment") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.belongsTo("meetingSpeaker", onDelete: .cascade).notNull()
                t.belongsTo("participant", onDelete: .setNull)
                t.column("method", .text).notNull()
                t.column("decision", .text).notNull()
                t.column("similarity", .double)
                t.column("margin", .double)
                t.column("threshold", .double)
                t.column("note", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("supersededAt", .datetime)
            }

            try db.create(table: "aiAnalysis") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("provider", .text).notNull()
                t.column("model", .text)
                t.column("providerVersion", .text)
                t.column("promptVersion", .text).notNull()
                t.column("sharedContentSummary", .text).notNull()
                t.column("status", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("durationSeconds", .double)
                t.column("executiveSummary", .text)
                t.column("technicalSummary", .text)
                t.column("rawOutput", .text)
                t.column("errorMessage", .text)
            }

            try db.create(table: "analysisItem") { t in
                t.primaryKey("id", .text)
                t.belongsTo("analysis", inTable: "aiAnalysis", onDelete: .cascade).notNull()
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("category", .text).notNull()
                t.column("nature", .text).notNull()
                t.column("text", .text).notNull()
                t.column("ownerName", .text)
                t.belongsTo("ownerParticipant", inTable: "participant", onDelete: .setNull)
                t.column("dueText", .text)
                t.belongsTo("evidenceSegment", inTable: "transcriptSegment", onDelete: .setNull)
                t.column("evidenceQuote", .text)
                t.column("evidenceStartTime", .double)
                t.column("evidenceSpeakerName", .text)
                t.column("evidenceStatus", .text).notNull()
                t.column("orderIndex", .integer).notNull()
                t.column("completedAt", .datetime)
            }
            try db.create(virtualTable: "analysisItemFts", using: FTS5()) { t in
                t.synchronize(withTable: "analysisItem")
                t.tokenizer = .unicode61()
                t.column("text")
                t.column("evidenceQuote")
                t.column("ownerName")
            }

            try db.create(table: "aiProviderConfiguration") { t in
                t.primaryKey("provider", .text)
                t.column("isEnabled", .boolean).notNull()
                t.column("executablePath", .text)
                t.column("model", .text)
                t.column("timeoutSeconds", .double).notNull()
                t.column("remoteSharingConsentAt", .datetime)
                t.column("lastDetectedVersion", .text)
                t.column("lastCheckedAt", .datetime)
                t.column("endpoint", .text)
            }

            try db.create(table: "processingJob") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("trackId", .text)
                t.column("stage", .text).notNull()
                t.column("status", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("audioSeconds", .double)
                t.column("wallSeconds", .double)
                t.column("peakMemoryBytes", .integer)
                t.column("detail", .text)
                t.column("errorMessage", .text)
            }

            try db.create(table: "correctionEvent") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade)
                t.column("entityType", .text).notNull()
                t.column("entityId", .text).notNull()
                t.column("field", .text).notNull()
                t.column("previousValue", .text)
                t.column("newValue", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "vocabularyTerm") { t in
                t.primaryKey("id", .text)
                t.column("canonical", .text).notNull().unique(onConflict: .replace)
                t.column("variantsJSON", .blob).notNull()
                t.column("category", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }

        // v2: any conversation app as source; intentional microphone pauses.
        migrator.registerMigration("v2-conversation-apps") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "sourceAppBundleID", .text)
                t.add(column: "sourceAppName", .text)
            }
            try db.execute(sql: """
                UPDATE meeting SET sourceAppBundleID = 'com.microsoft.teams2', sourceAppName = 'Microsoft Teams'
                WHERE captureScope = 'teamsProcesses'
                """)
            // Reasoning effort per provider and as provenance of each analysis.
            try db.alter(table: "aiProviderConfiguration") { t in t.add(column: "effort", .text) }
            try db.alter(table: "aiAnalysis") { t in t.add(column: "effort", .text) }
            try db.create(table: "recordingPause") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("source", .text).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("reason", .text).notNull()
            }
        }

        // v3: persistent chat history (per meeting and cross-meeting).
        migrator.registerMigration("v3-chat-history") { db in
            try db.create(table: "chatMessage") { t in
                t.primaryKey("id", .text)
                t.column("thread", .text).notNull()
                t.belongsTo("meeting", onDelete: .cascade)
                t.column("question", .text).notNull()
                t.column("answerJSON", .blob)
                t.column("scopeJSON", .blob)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "chatMessage_thread", on: "chatMessage", columns: ["thread", "meetingId", "createdAt"])
            try db.create(table: "chatMessageSource") { t in
                t.belongsTo("chatMessage", onDelete: .cascade).notNull()
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.primaryKey(["chatMessageId", "meetingId"])
            }
            // A deleted meeting must not survive as quoted text in the cross-meeting history.
            // BEFORE: the source links are still there (cascade runs with the delete itself).
            try db.execute(sql: """
                CREATE TRIGGER chatMessage_deleteWithCitedMeeting BEFORE DELETE ON meeting BEGIN
                    DELETE FROM chatMessage WHERE id IN
                        (SELECT chatMessageId FROM chatMessageSource WHERE meetingId = OLD.id);
                END
                """)
        }

        // v4: text embeddings for opt-in semantic search (TD-25). Rebuildable cache.
        migrator.registerMigration("v4-segment-embeddings") { db in
            try db.create(table: "segmentEmbedding") { t in
                t.primaryKey("segmentId", .text)
                    .references("transcriptSegment", onDelete: .cascade)
                t.column("model", .text).notNull()
                // Hash of the embedded text: an edited segment is re-embedded.
                t.column("textHash", .text).notNull()
                t.column("vector", .blob).notNull()
            }
        }

        migrator.registerMigration("v5-video-assets") { db in
            try db.create(table: "videoAsset") { t in
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.primaryKey(["meetingId"])
                t.column("relativePath", .text).notNull()
                t.column("windowTitle", .text).notNull()
                t.column("applicationName", .text).notNull()
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("durationSeconds", .double).notNull()
                t.column("fileSizeBytes", .integer).notNull()
                t.column("state", .text).notNull()
            }
        }

        migrator.registerMigration("v6-speaker-assignment-archive") { db in
            try db.create(table: "speakerAssignmentArchive") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("meetingSpeakerId", .text).notNull()
                t.column("speakerSource", .text).notNull()
                t.column("speakerClusterKey", .text).notNull()
                t.column("speakerOrdinal", .integer).notNull()
                t.belongsTo("participant", onDelete: .setNull)
                t.column("method", .text).notNull()
                t.column("decision", .text).notNull()
                t.column("similarity", .double)
                t.column("margin", .double)
                t.column("threshold", .double)
                t.column("note", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("supersededAt", .datetime)
                t.column("archivedAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
