class AddWhyZeroToLog < ActiveRecord::Migration
  def change
    add_column :logs, :why_zero, :integer
  end
end
