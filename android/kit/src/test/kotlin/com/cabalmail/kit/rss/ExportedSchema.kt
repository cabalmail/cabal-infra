package com.cabalmail.kit.rss

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.sql.Connection
import java.sql.DriverManager

/**
 * The feed database on real SQLite, for the kit's JVM tests: built from
 * the schemas Room's compiler exports under `android/kit/schemas`, in
 * memory, through JDBC. There is no Room here, so a test runs the SQL it
 * is about, by hand.
 */
object ExportedSchema {
    private val directory = File("schemas/com.cabalmail.kit.rss.RssDatabase")

    /** The versions with an exported schema, ascending. */
    fun versions(): List<Int> =
        directory
            .listFiles { file -> file.extension == "json" }
            .orEmpty()
            .map { it.nameWithoutExtension.toInt() }
            .sorted()

    fun database(version: Int): JsonObject =
        Json
            .parseToJsonElement(File(directory, "$version.json").readText())
            .jsonObject
            .getValue("database")
            .jsonObject

    /** A database as Room creates it at [version]: every table, index and trigger of the exported schema. */
    fun created(version: Int): Connection =
        DriverManager.getConnection("jdbc:sqlite::memory:").also { connection ->
            for (entity in database(version).getValue("entities").jsonArray.map { it.jsonObject }) {
                val table = entity.getValue("tableName").jsonPrimitive.content

                fun statement(sql: String) = connection.run(sql.replace("\${TABLE_NAME}", table))
                statement(entity.getValue("createSql").jsonPrimitive.content)
                entity["indices"]?.jsonArray?.forEach {
                    statement(
                        it.jsonObject
                            .getValue("createSql")
                            .jsonPrimitive.content,
                    )
                }
                entity["contentSyncTriggers"]?.jsonArray?.forEach { statement(it.jsonPrimitive.content) }
            }
        }
}

fun Connection.run(
    sql: String,
    vararg binds: Any,
) {
    prepareStatement(sql).use { statement ->
        binds.forEachIndexed { index, value -> statement.setObject(index + 1, value) }
        statement.execute()
    }
}

fun Connection.rows(
    sql: String,
    vararg binds: Any,
): List<List<String?>> =
    prepareStatement(sql).use { statement ->
        binds.forEachIndexed { index, value -> statement.setObject(index + 1, value) }
        statement.executeQuery().use { result ->
            val columns = result.metaData.columnCount
            buildList {
                while (result.next()) add((1..columns).map { result.getString(it) })
            }
        }
    }
