require 'set'

module Fastlane
  module Actions
    module SharedValues
      FL_CHANGELOG_SLACK_ATTACHMENT = :FL_CHANGELOG_SLACK_ATTACHMENT
    end
    class JirachangelogAction < Action
      def self.run(params)
        # Include jira-ruby
        Actions.verify_gem!('jira-ruby')
        require 'jira-ruby'

        # Make sure that the clone is not shallow, since with a shallow clone
        # we were not able to get any tags.
        if is_shallow_clone()
          UI.user_error!("Your checkout is a shallow clone. Ensure that tags are pulled before creating the changelog.")

          return false
        end

        tag = last_tag(params[:tag_match_pattern])
        return unless tag && !tag.empty?

        commits = commits_since_tag(tag)
        issue_ids = issue_ids_from_commits(commits)

        client = create_jira_client(
          params[:jira_url],
          params[:jira_user],
          params[:jira_password]
        )
        issues = get_issues_from_jira(client, issue_ids)

        sections = generate_sections(issues)

        Actions.lane_context[SharedValues::FL_CHANGELOG_SLACK_ATTACHMENT] = render_slack_attachment(sections)

        Actions.lane_context[SharedValues::FL_CHANGELOG] = render_markdown(sections)
      end

      #####################################################
      # @!group Detecting shallow clone
      #####################################################

      def self.is_shallow_clone
        # See: https://stackoverflow.com/a/37533086
        git_command = '[ -f $(git rev-parse --git-dir)/shallow ] && echo true || echo false'
        shell_return_value = Actions.sh(git_command, log: false)

        # Remove any line breaks.
        shell_return_value.gsub("\n", "") == "true"
      end

      #####################################################
      # @!group Getting issue IDs from Git
      #####################################################

      def self.last_tag(tag_match_pattern = "*")
        git_command = "git describe --abbrev=0 --tag --match \"#{tag_match_pattern}\""

        # The Git command will return a non-zero exit code when no tag was found.
        # Use try/catch to avoid this from showing up as an error.
        begin
          tag = Actions.sh(git_command)
        rescue
          UI.error "Unable to create changelog: No tag matches the pattern '#{tag_match_pattern}'."
          return
        end

        # Make sure the tag has no linebreak at the end.
        tag.gsub("\n", "")
      end

      def self.commits_since_tag(tag)
        cmd = "git log #{tag}..HEAD --format=\"%s\""

        all_commits = Actions.sh(cmd, log: false)

        # Remove duplicate newlines.
        commits_without_duplicate_newlines = all_commits.gsub("\n\n", "\n")

        # Split the lines into an array.
        commits = commits_without_duplicate_newlines.split("\n")

        UI.message("Found #{commits.count} commits")

        commits
      end

      def self.issue_ids_from_commits(commits)
        issue_ids = Set.new

        regular_expression = /[A-Z]+-\d+/

        commits.each { |message|
          issue_ids_from_message = message.scan(regular_expression)
          issue_ids_from_message.each { |issue_id|
            issue_ids.add(issue_id)
          }
        }

        UI.message("Detected #{issue_ids.count} issue IDs:")
        issue_ids.each { |issue_id|
          UI.message("- #{issue_id}")
        }

        issue_ids.to_a
      end

      #####################################################
      # @!group Jira
      #####################################################

      def self.create_jira_client(url, username, password)
        options = {
          :site => url,
          :context_path => '',
          :auth_type => :basic,
          :username => username,
          :password => password,
        }

        JIRA::Client.new(options)
      end

      def self.get_issues_from_jira(jira_client, issue_ids)
        UI.message("Downloading issue details from Jira...")

        issues = []

        issue_ids.each { |issue_id|
          begin
            single_issue = jira_client.Issue.find(issue_id)

            issues.push single_issue
          rescue StandardError => error
            UI.error "Failed to download issue #{issue_id}: #{error.message}"
          end
        }

        issues
      end


      #####################################################
      # @!group Grouping issues into sections
      #####################################################

      class Section
        def initialize(title)
          @title = title
          @issues = []
        end

        def title
          @title
        end

        def issues
          @issues
        end

        def add(issue)
          @issues.push issue
        end
      end

      def self.generate_sections(jira_issues)
        # Map issue types
        feature_types = ["Story, Task"]
        refactoring_types = ["Refactoring"]
        bug_types = ["Bug", "InstaBug"]

        feature_section = Section.new("Features")
        refactoring_section = Section.new("Refactorings")
        bug_section = Section.new("Bugs")
        section_for_any_other_issue_type = Section.new("Other improvements")

        jira_issues.each { |issue|
          issue_type = issue.issuetype.name

          if feature_types.include? issue_type
            feature_section.add(issue)
          elsif refactoring_types.include? issue_type
            refactoring_section.add(issue)
          elsif bug_types.include? issue_type
            bug_section.add(issue)
          else
            section_for_any_other_issue_type.add(issue)
          end
        }

        all_sections = [feature_section, refactoring_section, bug_section, section_for_any_other_issue_type]

        # Only return sections that are not empty
        all_sections.select{ |section|
          !section.issues.empty?
        }
      end

      #####################################################
      # @!group Render using Markdown
      #####################################################

      def self.render_markdown(sections)
        lines = []

        sections.each { |section|
          lines.push "\#\# #{section.title}"

          section.issues.each { |issue|
            lines.push render_issue(issue)
          }

          # Add an empty line between two sections.
          lines.push "" unless section.equal? sections.last
        }

        lines.join("\n")
      end

      def self.render_issue(issue)
        "- #{issue.summary} (#{issue.key})"
      end

      #####################################################
      # @!group Render Slack attachment
      #####################################################

      def self.render_slack_attachment(sections)
        # Without sections, we are not able to create an attachment.
        return unless !sections.empty?

        fields = sections.map { |section| self.render_slack_section_field(section) }

        {
            "fallback": render_slack_fallback_text(sections),
            "color": "#069d4f",
            "fields": fields
        }
      end

      def self.render_slack_fallback_text(sections)

        section_summaries = sections.map { |section| "#{section.issues.count} #{section.title}" }

        # If there was only one section, we don't need to continue any further.
        return section_summaries.first unless section_summaries.count > 1

        # Combine the first summaries with a comma
        # and append the last one using "and".
        every_summary_but_the_last = section_summaries.take(section_summaries.count - 1)
        last_summary = section_summaries.last

        first_part = every_summary_but_the_last.join(", ")

        [first_part, last_summary].join(" and ")
      end

      def self.render_slack_section_field(section)
        {
            "title": section.title,
            "value": self.render_slack_issue_list_string(section.issues),
            "short": false
        }
      end

      def self.render_slack_issue_list_string(issues)
        issue_lines = issues.map { |issue|
          issue_string = self.render_slack_issue(issue)

          # Encode the required characters.
          # See: https://api.slack.com/docs/message-formatting#how_to_escape_characters
          {
            '&': "&amp;",
            "<": "&lt;",
            ">": "&gt;"
          }.each do |character, replacement|
            issue_string = issue_string.gsub("#{character}", "#{replacement}")
          end

          issue_string
        }

        issue_lines.join("\n")
      end

      def self.render_slack_issue(issue)
        "• #{issue.summary} (#{issue.key})"
      end

      #####################################################
      # @!group Documentation
      #####################################################

      def self.description
        "Combine Git commit messages with Jira into a changelog"
      end

      def self.details
        "Commit messages are scanned for issue IDs, which are then used to look up issue details on Jira"
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :jira_url,
                                       env_name: "FL_JIRACHANGELOG_JIRA_URL", # The name of the environment variable
                                       description: "The URL of your Jira installation", # a short description of this parameter
                                       verify_block: proc do |value|
                                          UI.user_error!("No Jira URL for JirachangelogAction given, pass using `jira_url: 'https://jira.mycompany.it'`") unless (value and not value.empty?)
                                       end),
          FastlaneCore::ConfigItem.new(key: :jira_user,
                                       env_name: "FL_JIRACHANGELOG_JIRA_USER", # The name of the environment variable
                                       description: "The username for authenticating against Jira", # a short description of this parameter
                                       verify_block: proc do |value|
                                          UI.user_error!("No Jira user for JirachangelogAction given, pass using `jira_user: 'changelogbot'`") unless (value and not value.empty?)
                                       end),
          FastlaneCore::ConfigItem.new(key: :jira_password,
                                       env_name: "FL_JIRACHANGELOG_JIRA_PASSWORD",
                                       description: "Password for Jira",
                                       sensitive: true,
                                       verify_block: proc do |value|
                                         UI.user_error!("No Jira password for JirachangelogAction given, pass using `jira_password: 'cryp71cp455w0rd'`") unless (value and not value.empty?)
                                       end),
          FastlaneCore::ConfigItem.new(key: :tag_match_pattern,
                                       env_name: "FL_JIRACHANGELOG_TAG_MATCH_PATTERN",
                                       description: "Pattern that tags are matched against when looking for the last tag",
                                       default_value: "*")
        ]
      end

      def self.output
        [
          ['FL_CHANGELOG', 'The changelog string generated from the Git commit messages and Jira issues'],
          ['FL_CHANGELOG_SLACK_ATTACHMENT', 'The changelog as a Slack message attachment']
        ]
      end

      def self.authors
        ["@wtimme"]
      end

      def self.is_supported?(platform)
        true
      end
    end
  end
end
