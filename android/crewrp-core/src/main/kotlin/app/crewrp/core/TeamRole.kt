package app.crewrp.core

enum class TeamRole {
    ADMIN,
    MEMBER,
    NONE;

    val canEdit: Boolean get() = this == ADMIN

    companion object {
        const val ADMIN_SLUG = "admins"
        const val MEMBER_SLUG = "members"

        fun resolve(slugs: Collection<String>): TeamRole {
            val set = slugs.toSet()
            if (ADMIN_SLUG in set) return ADMIN
            if (MEMBER_SLUG in set) return MEMBER
            return NONE
        }
    }
}

data class Session(
    val org: String,
    val repo: String,
    val teamRole: TeamRole,
)
