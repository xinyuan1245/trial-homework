package campaign

// Campaign represents an ad campaign
type Campaign struct {
	ID          string
	CreativeURL string
}

// Manager handles the business logic for campaign selection
type Manager struct{}

// NewManager creates a new Manager
func NewManager() *Manager {
	return &Manager{}
}

// SelectCampaign chooses a campaign based on user_idfv.
// Returns nil if no campaign is selected.
func (m *Manager) SelectCampaign(userIDFV string) *Campaign {
	if userIDFV == "123" {
		return &Campaign{
			ID:          "campaign1",
			CreativeURL: "https://example.com/creative/campaign1.png",
		}
	}
	if userIDFV == "456" {
		return &Campaign{
			ID:          "campaign2",
			CreativeURL: "https://example.com/creative/campaign2.png",
		}
	}
	if userIDFV == "789" {
		return nil
	}
	return &Campaign{
		ID:          "campaign_default",
		CreativeURL: "https://example.com/creative/campaign_default.png",
	}
}
