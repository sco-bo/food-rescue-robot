require 'logger'
require 'csv'

module FoodRobot

  # Set to true to disable emailing and just print the emails to STDOUT
  @@DontDeliverEmails = false

  # Given a date, generates the corresponding log entries for that
  # date based on the /current/ schedule
  def self.generate_log_entries(d = Time.zone.today,absence = nil)
    n = 0
    n_skipped = 0
    is_done = {}
    logs = Log.select("id, schedule_chain_id, donor_id").where('logs.when = ?',d)

    logs.each do |log|
      k = "#{log.schedule_chain_id}:#{log.donor_id}"
      is_done[k] = log.id
    end

    # if volunteer is specified, we're generating an absence so proceed with ones for
    # whom that volunteer is the only volunteer
    if absence.nil?
      schedules = ScheduleChain.where("NOT irregular")
    else
      schedules = absence.volunteer.schedule_chains
    end

    schedules.each do |schedule|
      # don't generate logs for malformed schedules
      next unless schedule.functional?
      # things that are relevant to this day
      next if schedule.one_time? and schedule.detailed_date != d
      next if schedule.weekly? and schedule.day_of_week != d.wday

      puts "Schedule Chain: " + schedule.schedules.collect{ |ss|
        ss.location.nil? ? nil : ((ss.is_pickup_stop? ? "D" : "R") + ss.location.id.to_s)
      }.compact.join(" -> ")

      ssi_last = schedule.schedules.length - 1

      schedule.schedules.each_with_index do |ss, ssi|
        # don't insert a duplicate log entry if one already exists
        # e.g. generating logs from a chain (D1->D2->R1->D3->R2)
        # results in two logs
        #
        # D1 -> {R1,R2}
        # D2 -> {R1,R2}
        # D3 -> {R2}
        #
        # and (D1->D2->D3->D4->R1) will be four logs:
        #
        # D1 -> {R1}
        # D2 -> {R1}
        # D3 -> {R1}
        # D4 -> {R1}
        #
        # Note: Hub acts like a donor when it's not the last location, otherwise acts like
        #       a recipient
        next if not ss.is_pickup_stop? or ss.location_id.nil? or ((ssi==ssi_last) and ss.location.hub?)

        if is_done["#{schedule.id}:#{ss.location.id}"].nil?
          # normal case, generate a new log
          log = Log.from_donor_schedule(ss, ssi, d, absence)
          log.save
          n += 1
        else
          if absence.nil?
            # already generated, skip it
            n_skipped += 1
          else
            # deal with any already generated logs that are now covered with absences
            log = Log.find(is_done["#{schedule.id}:#{ss.location.id}"])
            log.volunteers -= [absence.volunteer]
            log.absences << absence
            log.save
            n += 1
          end
          next
        end
      end
    end
    return [n, n_skipped]
  end

  # Sends an email to any volunteer who has a outstanding log entry
  # from n or more days ago. Also sends an email to the admin summarizing
  # all logs that have seen at least r reminders.
  def self.send_reminder_emails(n=2, r=3)
    naughty_list = {}
    reminder_list = {}
    short_term_cover_list = {}
    pre_reminder_list = {}
    c = 0

    Log.where("NOT complete").each{ |log|
      # FUTURE reminders...
      days_future = (log.when - Time.zone.today).to_i

      if days_future == 1 and !log.volunteers.empty?
        log.volunteers.reject{ |v| not v.pre_reminders_too }.each{ |v|
          pre_reminder_list[v] = [] if pre_reminder_list[v].nil?
          pre_reminder_list[v].push(log)
        }
        next
      elsif (days_future == 1 or days_future == 2) and log.volunteers.empty?
        short_term_cover_list[log.region] = [] if short_term_cover_list[log.region].nil?
        short_term_cover_list[log.region].push(log)
      end

      # PAST reminders...
      next if log.volunteers.empty?
      days_past = (Time.zone.today - log.when).to_i
      next unless days_past >= n

      log.num_reminders = 0 if log.num_reminders.nil?
      log.num_reminders += 1
      log.save

      log.volunteers.each{ |v|
        reminder_list[v] = [] if reminder_list[v].nil?
        reminder_list[v].push(log)

        if log.num_reminders >= r
          naughty_list[log.region] = [] if naughty_list[log.region].nil?
          naughty_list[log.region].push(log)
        end
      }
    }

    # Send reminders to enter data for PAST pickups
    reminder_list.each{ |v, logs|
      m = Notifier.volunteer_log_reminder(v, logs)
      if @@DontDeliverEmails
        puts m
      else
        m.deliver
      end
      c += 1

      if v.sms_too and !v.sms_email.nil?
        m = Notifier.volunteer_log_sms_reminder(v,logs)
        if @@DontDeliverEmails
          puts m
        else
          m.deliver
        end
      end
    }

    # Send reminders to do FUTURE pickups
    pre_reminder_list.each{ |v,logs|
      m = Notifier.volunteer_log_pre_reminder(v,logs)
      if @@DontDeliverEmails
        puts m
      else
        m.deliver
      end
      c += 1

      if v.sms_too and !v.sms_email.nil?
        m = Notifier.volunteer_log_sms_pre_reminder(v,logs)
        if @@DontDeliverEmails
          puts m
        else
          m.deliver
        end
      end
    }

    # Remind the admins to cover things without a volunteer...
    if short_term_cover_list.length > 0
      short_term_cover_list.each{ |region, logs|
        m = Notifier.admin_short_term_cover_summary(region, logs)
        if @@DontDeliverEmails
          puts m
        else
          m.deliver
        end
      }
    end

    # Let the admin know about tardy data entry
    if naughty_list.length > 0
      naughty_list.each{ |region, logs|
        m = Notifier.admin_reminder_summary(region, logs)
        if @@DontDeliverEmails
          puts m
        else
          m.deliver
        end
      }
    end
    return c
  end

  def self.send_weekly_pickup_summary
    Region.all.each{ |r|
      puts r.name
      lbs = 0.0
      flagged_logs = []
      biggest = nil
      num_logs = Log.where('region_id = ? AND "when" > ? AND "when" < ?',r.id,Time.zone.today-7,Time.zone.today).count
      num_entered = 0
      next unless num_logs > 0
      puts num_logs
      zero_logs = []

      logs = Log.joins(:log_parts).select("sum(weight) as weight_sum, sum(count) as count_sum, logs.id, flag_for_admin").where('region_id = ? AND "when" > ? AND "when" < ? AND complete',r.id,Time.zone.today-7,Time.zone.today).group("logs.id, flag_for_admin")

      logs.each{ |log|
        lbs += log.weight_sum.to_f
        zero_logs.push(Log.find(log.id)) if log.weight_sum.to_f == 0.0 and log.count_sum.to_f == 0.0
        flagged_logs << Log.find(log.id) if log.flag_for_admin
        biggest = l if biggest.nil? or log.weight_sum.to_f > biggest.weight_sum.to_f
        num_entered += 1
      }
      next if biggest.nil?
      biggest = Log.find(biggest.id)
      m = Notifier.admin_weekly_summary(r,lbs,flagged_logs,biggest,num_logs,num_entered,zero_logs)
      if @@DontDeliverEmails
        puts m
      else
        m.deliver
      end
    }
  end

end
